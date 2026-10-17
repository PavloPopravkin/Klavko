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

    /// The microphone's loudness for the panel's wave.
    let meter = VoiceMeter()

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

    /// Return / Enter while dictating inserts what was heard (and never reaches the app, where it
    /// could send a half-written message); used up while recognizing too.
    func handleReturn() -> Bool {
        switch stage {
        case .listening:
            finish()
            return true
        case .finishing:
            return true
        case .idle, .failed:
            return false
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
        let meter = meter
        fanout.onLevel = { level in
            DispatchQueue.main.async { MainActor.assumeIsolated { meter.push(level) } }
        }
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
        fanout.onLevel = nil
        meter.reset()
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
        for index in 0..<VoiceMeter.count { meter.push(Float(0.02 + 0.1 * abs(sin(Double(index) / 3)))) }
        let view = NSHostingView(rootView: VoiceIndicator(dictation: self, meter: meter).padding(20)
            .background(Color(white: 0.85)))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    fileprivate func closeFailure() {
        stage = .idle
        hidePanel()
    }

    private var resizeObserver: NSObjectProtocol?

    private func showPanel() {
        if panel == nil {
            let hosting = NSHostingController(rootView: VoiceIndicator(dictation: self, meter: meter))
            hosting.sizingOptions = [.preferredContentSize]
            let panel = IndicatorPanel(contentViewController: hosting)
            panel.styleMask = [.nonactivatingPanel, .borderless]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false  // the capsule and the bubble draw their own
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
            // The text grows the panel upwards; keep it centred at the bottom.
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.placePanel() }
            }
        }
        placePanel()
        // Never takes the keyboard: typing goes on in the app where the text will be inserted.
        panel?.orderFrontRegardless()
    }

    /// Bottom centre of the screen with the mouse, above the Dock.
    private func placePanel() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = panel.isVisible ? (panel.screen ?? NSScreen.main)
            : (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: (frame.midX - panel.frame.width / 2).rounded(), y: frame.minY + 24)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }
}

/// Recent microphone loudness, newest last, each 0…1; drives the panel's wave.
@MainActor
final class VoiceMeter: ObservableObject {
    static let count = 28
    @Published private(set) var levels = [CGFloat](repeating: 0, count: VoiceMeter.count)

    /// `rms` of one audio buffer.
    func push(_ rms: Float) {
        // Speech sits around -50…-10 dB; map that range to 0…1.
        let decibels = 20 * log10(max(rms, 0.000_01))
        let level = CGFloat(min(max((decibels + 52) / 40, 0), 1))
        levels.removeFirst()
        levels.append(level)
    }

    func reset() {
        levels = [CGFloat](repeating: 0, count: Self.count)
    }
}

/// Its buttons take a click without activating Klavko.
private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A dark capsule with a live wave (like Wispr Flow) and, above it, a bubble with what is being heard.
private struct VoiceIndicator: View {
    @ObservedObject var dictation: VoiceDictation
    @ObservedObject var meter: VoiceMeter

    private static let width: CGFloat = 440

    var body: some View {
        VStack(spacing: 8) {
            bubble
            capsule
        }
        .frame(width: Self.width)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)  // room for the shadows
    }

    // MARK: Bubble with the text

    @ViewBuilder private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .failed(let message) = dictation.stage {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(dictation.text.isEmpty ? "Говоріть…" : dictation.text)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(dictation.text.isEmpty ? 0.5 : 0.95))
                    .lineLimit(4)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.15), value: dictation.text)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private var hint: String {
        switch dictation.stage {
        case .finishing: "Розпізнаю…"
        default: "Enter або гаряча клавіша — вставити · Esc — скасувати · \(dictation.languageTitle)"
        }
    }

    // MARK: Capsule with the wave

    private var capsule: some View {
        HStack(spacing: 10) {
            roundButton("xmark", filled: false, help: "Скасувати (Esc)") {
                if case .failed = dictation.stage { dictation.closeFailure() } else { dictation.cancel() }
            }
            Group {
                if dictation.stage == .finishing {
                    ThinkingWave()
                } else {
                    Waveform(levels: meter.levels, muted: dictation.stage != .listening)
                }
            }
            .frame(width: 150, height: 28)
            if dictation.stage == .listening {
                roundButton("checkmark", filled: true, help: "Вставити (Enter)") { dictation.toggle() }
            } else {
                Color.clear.frame(width: 26, height: 26)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.88)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    private func roundButton(_ symbol: String, filled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(filled ? Color.black : Color.white.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(Circle().fill(filled ? Color.white : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Bars that follow the voice: the newest loudness in the middle, older ones fading out to the sides.
private struct Waveform: View {
    let levels: [CGFloat]
    let muted: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<levels.count, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(muted ? 0.35 : 0.95))
                    .frame(width: 3, height: height(index))
            }
        }
        .animation(.easeOut(duration: 0.09), value: levels)
    }

    /// Bars mirror around the centre, which shows the latest level.
    private func height(_ index: Int) -> CGFloat {
        let half = levels.count / 2
        let distance = abs(index - half)
        let level = levels[max(levels.count - 1 - distance * 2, 0)]
        let taper = 1 - CGFloat(distance) / CGFloat(half + 2)
        return 3 + 25 * level * taper
    }
}

/// A gentle travelling wave while the recording is being recognized.
private struct ThinkingWave: View {
    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<VoiceMeter.count, id: \.self) { index in
                    let phase = sin(time * 5 - Double(index) * 0.45)
                    Capsule()
                        .fill(.white.opacity(0.55 + 0.35 * phase))
                        .frame(width: 3, height: 4 + 7 * (phase + 1))
                }
            }
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
    private var levelHandler: (@Sendable (Float) -> Void)?

    /// Gets each buffer's loudness (RMS), on the audio thread.
    var onLevel: (@Sendable (Float) -> Void)? {
        get { lock.withLock { levelHandler } }
        set { lock.withLock { levelHandler = newValue } }
    }

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
        if let onLevel, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            onLevel((sum / Float(buffer.frameLength)).squareRoot())
        }
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
