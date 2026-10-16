import AppKit
import AVFoundation
import FluidAudio
import KlavkoCore
import Speech
import SwiftUI

/// Local voice input: records the microphone, recognizes speech on this Mac (macOS speech recognition,
/// on-device only — no audio leaves the computer) and types the text at the caret.
///
/// macOS runs one on-device recognition at a time, so in automatic mode it listens in the layout's
/// language and keeps the audio; when you stop, the recording is recognized again in the other language
/// and the text with more real words of its language wins. (Checking only "doubtful" results isn't enough:
/// Ukrainian speech heard as English can still be mostly English words — "Super Vika yak no soda".)
@MainActor
final class VoiceDictation: ObservableObject {
    enum Stage: Equatable {
        case idle
        case listening
        case finishing
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var text = ""
    @Published private(set) var languageTitle = ""

    /// Languages to consider ("uk", "en"); asked each time recording starts.
    var languages: () -> [String] = { ["uk", "en"] }
    /// The better recognizer, once its model is downloaded; macOS speech recognition otherwise.
    var parakeet: ParakeetEngine?
    /// The language to listen in first (the keyboard layout's).
    var preferredLanguage: () -> String = { "uk" }
    /// Called after text was typed (so key tracking can start afresh).
    var onInserted: () -> Void = {}

    var isActive: Bool { stage == .listening || stage == .finishing }

    private let audio = AVAudioEngine()
    private let fanout = AudioFanout()
    private let spellChecker = MacSpellChecker()
    private var live: Recognition?
    private var others: [String] = []
    private var panel: NSPanel?
    /// Insert when the result is ready (false: cancelled).
    private var insertOnFinish = false
    private var secondPassRunning = false
    /// Languages the user speaks (from settings) for this recording.
    private var allowed: [String] = ["uk", "en"]
    private var completed = false
    /// Numbers each recording. Timers and results check it, so a late one from an earlier recording
    /// can't finish (and insert into) the current one.
    private var session = 0
    private var finishingSince: Date?

    /// The hotkey: starts listening, or finishes and inserts what was heard.
    func toggle() {
        switch stage {
        case .listening:
            finish()
        case .finishing:
            // Recognition should take well under a second; if it's stuck, let the key start afresh.
            if let since = finishingSince, Date().timeIntervalSince(since) > 5 {
                Log.engine.notice("Voice input was stuck finishing; starting over")
                start()
            }
        case .idle, .failed:
            start()
        }
    }

    func cancel() {
        session += 1
        insertOnFinish = false
        stopAudio()
        live?.cancel()
        cleanUp()
    }

    // MARK: - Recording

    private func start() {
        cancel()
        text = ""
        completed = false
        let codes = languages()
        let first = codes.contains(preferredLanguage()) ? preferredLanguage() : (codes.first ?? "uk")
        others = codes.filter { $0 != first }
        allowed = codes
        // Load Parakeet while the user speaks.
        if let parakeet, parakeet.isDownloaded { parakeet.prepare() }
        languageTitle = Self.title(first)
        showPanel()
        let current = session
        Task { [weak self] in
            guard let self else { return }
            let permitted = await Self.requestPermissions()
            guard session == current else { return }
            guard permitted else {
                stage = .failed("Немає доступу до мікрофона або розпізнавання мовлення. Дозвольте його в System Settings → Privacy & Security.")
                return
            }
            begin(first)
        }
    }

    private func begin(_ code: String) {
        guard let recognizer = Self.recognizer(code) else {
            stage = .failed("Розпізнавання мовлення на пристрої недоступне. Увімкніть Диктування в System Settings → Keyboard, щоб macOS завантажила мовні моделі.")
            return
        }
        let recognition = Recognition(language: code, recognizer: recognizer, fanout: fanout,
                                      isListening: { [weak self] in self?.stage == .listening },
                                      changed: { [weak self] in self?.update() })
        live = recognition
        fanout.startRecording(keep: !others.isEmpty || parakeet?.isDownloaded == true)
        Self.feed(audio.inputNode, into: fanout)
        recognition.startSegment()
        audio.prepare()
        do {
            try audio.start()
        } catch {
            stage = .failed("Не вдалося увімкнути мікрофон: \(error.localizedDescription)")
            return
        }
        insertOnFinish = true
        stage = .listening
        Log.engine.notice("Voice input started (\(code, privacy: .public))")
    }

    private func update() {
        guard let live else { return }
        text = live.text
        if live.failedForGood, stage == .listening {
            stopAudio()
            stage = .failed("Розпізнавання мовлення не працює. Перевірте мікрофон і Диктування в System Settings → Keyboard.")
            return
        }
        if stage == .finishing, live.isDone { liveFinished() }
    }

    /// Stop listening; the recognizer then delivers its final text.
    private func finish() {
        stage = .finishing
        finishingSince = Date()
        stopAudio()
        live?.endAudio()
        // If no final result comes (e.g. nothing was said), don't hang.
        let current = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, session == current, stage == .finishing, !secondPassRunning else { return }
            liveFinished()
        }
    }

    private func liveFinished() {
        guard !completed, !secondPassRunning, let live else { return }
        let heard = live.text
        if let parakeet, parakeet.isDownloaded, fanout.hasRecording {
            finishWithParakeet(parakeet, liveResult: (language: live.language, text: heard))
            return
        }
        guard let other = others.first, fanout.hasRecording else {
            complete(with: heard, language: live.language)
            return
        }
        recognizeAgain(in: other, comparingWith: (language: live.language, text: heard))
    }

    /// Recognizes the whole recording with Parakeet. It may hear Ukrainian as Russian; Russian is never
    /// inserted — the macOS Ukrainian recognizer redoes it then.
    private func finishWithParakeet(_ parakeet: ParakeetEngine, liveResult: (language: String, text: String)) {
        guard let file = fanout.writeRecording() else {
            complete(with: liveResult.text, language: liveResult.language)
            return
        }
        secondPassRunning = true
        let ukrainianAllowed = allowed.contains("uk")
        // Only one language: rule out the other alphabet outright.
        let hint: Language? = allowed == ["uk"] ? .ukrainian : allowed == ["en"] ? .english : nil
        let current = session
        Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                var text = try await parakeet.transcribe(file: file, language: hint)
                var language = "parakeet"
                if LanguageGuess.looksRussian(text) {
                    Log.engine.notice("Parakeet heard Russian; redoing with the Ukrainian recognizer")
                    text = ukrainianAllowed ? await Self.recognize(file: file, language: "uk") : ""
                    language = "uk (macOS)"
                }
                guard let self, session == current else { return }
                complete(with: text, language: language)
            } catch {
                Log.engine.error("Parakeet failed: \(error.localizedDescription, privacy: .public)")
                guard let self, session == current else { return }
                complete(with: liveResult.text, language: liveResult.language)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, session == current else { return }
            complete(with: liveResult.text, language: liveResult.language)
        }
    }

    private func recognizeAgain(in code: String, comparingWith first: (language: String, text: String)) {
        guard let file = fanout.writeRecording() else {
            complete(with: first.text, language: first.language)
            return
        }
        languageTitle = "перевіряю: \(Self.title(code))"
        secondPassRunning = true
        let current = session
        Task { [weak self] in
            let heard = await Self.recognize(file: file, language: code)
            try? FileManager.default.removeItem(at: file)
            guard let self, session == current else { return }
            let best = LanguageGuess.best([first, (language: code, text: heard)],
                                          preferred: first.language, spellChecker: spellChecker) ?? first
            Log.engine.notice("Voice input compared \(first.language, privacy: .public) with \(code, privacy: .public)")
            complete(with: best.text, language: best.language)
        }
        // Don't wait forever for the second opinion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, session == current else { return }
            complete(with: first.text, language: first.language)
        }
    }

    private func complete(with result: String, language: String) {
        guard !completed else { return }
        completed = true
        session += 1  // anything still pending belongs to a finished recording now
        if insertOnFinish && !result.isEmpty {
            insert(result)
            Log.engine.notice("Voice input chose \(language, privacy: .public)")
        }
        live?.cancel()
        cleanUp()
    }

    private func insert(_ text: String) {
        insertOnFinish = false
        // Separate from the word before the caret, if there is one.
        let before = CaretContext.textBeforeCaret(limit: 1) ?? ""
        let spaced = (before.last.map { !$0.isWhitespace } ?? false) ? " " + text : text
        TextInjector.type(spaced)
        onInserted()
        Log.engine.notice("Voice input inserted \(text.count) chars")
    }

    private func stopAudio() {
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
    }

    private func cleanUp() {
        live = nil
        secondPassRunning = false
        fanout.reset()
        if case .failed = stage { return }  // keep the message on screen until closed
        stage = .idle
        hidePanel()
    }

    /// Recognizes a whole recording. macOS reports each phrase after a pause from scratch, so partial
    /// results are joined like in live recognition. "" if nothing was heard or the language is unavailable.
    static func recognize(file: URL, language code: String) async -> String {
        guard let recognizer = recognizer(code) else { return "" }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        return await withCheckedContinuation { continuation in
            let joiner = PhraseCollector()
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let heard = result?.bestTranscription.formattedString { joiner.add(heard) }
                if result?.isFinal == true || error != nil {
                    joiner.finish { continuation.resume(returning: $0) }
                }
            }
        }
    }

    /// Developer check: recognizes an audio file in Ukrainian, then English, and prints both with the choice.
    static func check(file: URL) async -> String {
        guard await requestPermissions() else { return "no permission" }
        var results: [(language: String, text: String)] = []
        for code in ["uk", "en"] {
            results.append((code, await recognize(file: file, language: code)))
        }
        let checker = MacSpellChecker()
        let lines = results.map { "\($0.language) [\(String(format: "%.2f", LanguageGuess.wordShare($0.text, language: $0.language, spellChecker: checker)))]: \($0.text)" }
        let best = LanguageGuess.best(results, preferred: "en", spellChecker: checker)
        return (lines + ["chosen (layout en): \(best?.language ?? "-")"]).joined(separator: "\n")
    }

    private static func recognizer(_ code: String) -> SFSpeechRecognizer? {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: code == "uk" ? "uk-UA" : "en-US")),
              recognizer.supportsOnDeviceRecognition else { return nil }
        return recognizer
    }

    private static func title(_ code: String) -> String {
        code == "uk" ? "українська" : "англійська"
    }

    // Audio and recognition callbacks come on background threads, so they're built outside the main actor.

    /// Sends the microphone's audio to the running recognition (and the recording).
    private nonisolated static func feed(_ input: AVAudioInputNode, into fanout: AudioFanout) {
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            fanout.append(buffer)
        }
    }

    private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Indicator

    /// Developer check of the indicator's look: renders it while listening, with sample text.
    func snapshot(to url: URL) {
        stage = .listening
        languageTitle = "українська"
        text = "Привіт, я диктую цей текст голосом, а Klavko вставить його туди, де стоїть курсор."
        let view = NSHostingView(rootView: VoiceIndicator(dictation: self))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    fileprivate func closeFailure() {
        stage = .idle
        hidePanel()
    }

    private func showPanel() {
        if panel == nil {
            let hosting = NSHostingController(rootView: VoiceIndicator(dictation: self))
            hosting.sizingOptions = [.preferredContentSize]
            let panel = IndicatorPanel(contentViewController: hosting)
            panel.styleMask = [.nonactivatingPanel, .borderless]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        guard let panel else { return }
        // Bottom centre of the screen with the mouse, above the Dock.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 210, y: frame.minY + 40))
        }
        // Never takes the keyboard: typing goes on in the app where the text will be inserted.
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }
}

/// Its buttons take a click without activating Klavko.
private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct VoiceIndicator: View {
    @ObservedObject var dictation: VoiceDictation
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.7).repeatForever(), value: pulse)
                    .onAppear { pulse = true }
                Text(status).font(.headline)
                Spacer()
                Button {
                    if case .failed = dictation.stage { dictation.closeFailure() } else { dictation.cancel() }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Скасувати")
            }
            if case .failed(let message) = dictation.stage {
                Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(dictation.text.isEmpty ? "Говоріть…" : dictation.text)
                    .font(.callout)
                    .foregroundStyle(dictation.text.isEmpty ? .secondary : .primary)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text("Ще раз гаряча клавіша — вставити")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if dictation.stage == .listening {
                        Button("Вставити") { dictation.toggle() }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var status: String {
        switch dictation.stage {
        case .listening: "Слухаю · \(dictation.languageTitle)"
        case .finishing: "Розпізнаю…"
        case .failed: "Голосовий ввід"
        case .idle: "Голосовий ввід"
        }
    }
}

/// Passes microphone audio to the current recognition request and, when asked, keeps a copy in memory
/// for a second recognition in another language (from the audio thread).
private final class AudioFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String: SFSpeechAudioBufferRecognitionRequest] = [:]
    private var keep = false
    private var recording: [AVAudioPCMBuffer] = []
    /// About three minutes at 48 kHz; longer dictation keeps only the live result.
    private let maxFrames: AVAudioFrameCount = 48_000 * 180
    private var recordedFrames: AVAudioFrameCount = 0

    var hasRecording: Bool { lock.withLock { !recording.isEmpty } }

    func set(_ request: SFSpeechAudioBufferRecognitionRequest, for language: String) {
        lock.withLock { requests[language] = request }
    }

    func startRecording(keep: Bool) {
        lock.withLock {
            self.keep = keep
            recording = []
            recordedFrames = 0
        }
    }

    func reset() {
        lock.withLock {
            requests.removeAll()
            recording = []
            recordedFrames = 0
            keep = false
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let current = lock.withLock { () -> [SFSpeechAudioBufferRecognitionRequest] in
            if keep, recordedFrames + buffer.frameLength <= maxFrames, let copy = Self.copy(buffer) {
                recording.append(copy)
                recordedFrames += buffer.frameLength
            }
            return Array(requests.values)
        }
        current.forEach { $0.append(buffer) }
    }

    /// The recording as a temporary audio file (the caller deletes it).
    func writeRecording() -> URL? {
        let buffers = lock.withLock { recording }
        guard let format = buffers.first?.format else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("klavko-voice-\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            for buffer in buffers { try file.write(from: buffer) }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let target = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel], count: Int(buffer.frameLength))
        }
        return copy
    }
}

/// One language's recognition. macOS ends a recognition after a pause in speech; while listening,
/// a new segment starts and the finished ones are kept.
@MainActor
private final class Recognition {
    let language: String
    private let recognizer: SFSpeechRecognizer
    private let fanout: AudioFanout
    private let isListening: () -> Bool
    private let changed: () -> Void

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committed = ""
    private var segment = ""
    /// Tells the current segment's callbacks from late ones of a segment already replaced.
    private var segmentID = 0
    /// Segments in a row that ended in an error with nothing heard.
    private var emptyFailures = 0
    /// The last segment ended after the audio stopped: nothing more will come.
    private(set) var isDone = false

    var text: String { UtteranceJoiner.join(committed, segment) }
    var failedForGood: Bool { emptyFailures > 3 }

    init(language: String, recognizer: SFSpeechRecognizer, fanout: AudioFanout,
         isListening: @escaping () -> Bool, changed: @escaping () -> Void) {
        self.language = language
        self.recognizer = recognizer
        self.fanout = fanout
        self.isListening = isListening
        self.changed = changed
    }

    func startSegment() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true  // never send audio to a server
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        fanout.set(request, for: language)

        segmentID += 1
        let id = segmentID
        segment = ""
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] heard, isFinal, error in
            self?.handle(heard: heard, isFinal: isFinal, error: error, segment: id)
        })
    }

    func endAudio() {
        request?.endAudio()
    }

    func cancel() {
        segmentID += 1
        task?.cancel()
        task = nil
        request = nil
    }

    private func handle(heard: String?, isFinal: Bool, error: String?, segment id: Int) {
        guard id == segmentID else { return }
        if let heard {
            // A new phrase after a pause, in the same recognition: keep the previous one.
            if !segment.isEmpty, UtteranceJoiner.isRestart(previous: segment, next: heard) {
                committed = UtteranceJoiner.join(committed, segment)
            }
            segment = heard
        }
        if isFinal || error != nil {
            committed = text
            segment = ""
            // "No speech detected" just means a pause: not a failure.
            let silence = error?.hasSuffix("(1110)") ?? false
            if let error, !silence {
                Log.engine.notice("Voice segment (\(self.language, privacy: .public)) ended: \(error, privacy: .public)")
            }
            if isListening() {
                emptyFailures = error != nil && !silence && heard == nil ? emptyFailures + 1 : 0
                if !failedForGood { startSegment() }
            } else {
                isDone = true
            }
        }
        changed()
    }

    /// Hands each recognition update (text, final?, error) to `update` on the main thread.
    nonisolated static func resultHandler(
        _ update: @escaping @MainActor (String?, Bool, String?) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let heard = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error.map { ($0 as NSError).localizedDescription + " (\(($0 as NSError).code))" }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { update(heard, isFinal, failure) }
            }
        }
    }
}

/// Collects a file recognition's phrases (from a background thread).
private final class PhraseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var committed = ""
    private var current = ""
    private var finished = false

    func add(_ heard: String) {
        lock.withLock {
            if !current.isEmpty, UtteranceJoiner.isRestart(previous: current, next: heard) {
                committed = UtteranceJoiner.join(committed, current)
            }
            current = heard
        }
    }

    /// Calls `done` once with everything heard.
    func finish(_ done: (String) -> Void) {
        let text: String? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            return UtteranceJoiner.join(committed, current)
        }
        if let text { done(text) }
    }
}
