import AppKit
import KlavkoCore
import Vision

/// "Text from the screen": you drag over an area of the screen (the macOS screenshot crosshair, Esc
/// cancels), Klavko reads the text in it on this Mac (Vision) and hands it on to be translated.
/// Nothing is saved: the picture is a temporary file, deleted right after.
@MainActor
final class ScreenTextCapture {
    /// The text read (maybe empty) and the point where the area ended, for the panel.
    var onText: (String, NSPoint) -> Void = { _, _ in }
    var onProblem: (String, NSPoint) -> Void = { _, _ in }
    /// Languages to expect (the translation pair and the keyboard layouts').
    var languages: () -> [String] = { ["uk", "en"] }

    private var running = false

    func start() {
        guard !running else { return }
        // Reading the screen needs the Screen Recording permission; macOS asks once.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            onProblem(tr("Дозвольте Klavko запис екрана: System Settings → Privacy & Security → Screen & System Audio "
                         + "Recording. Потім перезапустіть Klavko й спробуйте ще раз.",
                         "Allow Klavko to record the screen: System Settings → Privacy & Security → Screen & System Audio "
                         + "Recording. Then restart Klavko and try again."), NSEvent.mouseLocation)
            return
        }
        running = true
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("klavko-ocr-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: drag to choose the area (Space for a window), -x: no sound, -o: no window shadow.
        process.arguments = ["-i", "-x", "-o", file.path]
        let candidates = Self.recognitionLanguages(languages())
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                running = false
                let point = NSEvent.mouseLocation
                // No file: the user pressed Esc.
                guard FileManager.default.fileExists(atPath: file.path) else { return }
                let text = await Self.recognize(file, languages: candidates)
                try? FileManager.default.removeItem(at: file)
                Log.engine.notice("Screen text: \(text.count) chars")
                onText(text, point)
            }
        }
        do {
            try process.run()
        } catch {
            running = false
            Log.engine.error("screencapture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Vision's names for our languages, those it supports, ours first.
    private static func recognitionLanguages(_ codes: [String]) -> [String] {
        let names = ["uk": "uk-UA", "en": "en-US", "ru": "ru-RU", "de": "de-DE", "fr": "fr-FR", "es": "es-ES",
                     "it": "it-IT", "pt": "pt-BR", "pl": "pl-PL", "tr": "tr-TR", "ar": "ar-SA", "he": "he-IL"]
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        var result: [String] = []
        for code in codes + ["uk", "en"] {
            if let name = names[code], supported.contains(name), !result.contains(name) { result.append(name) }
        }
        return result
    }

    /// The text in the picture, line by line from the top; side-by-side pieces of one line joined by a space.
    nonisolated static func recognize(_ file: URL, languages: [String]) async -> String {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            if !languages.isEmpty { request.recognitionLanguages = languages }
            let handler = VNImageRequestHandler(url: file)
            guard (try? handler.perform([request])) != nil, let observations = request.results else { return "" }
            let pieces = observations.compactMap { observation -> (box: CGRect, text: String)? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return (observation.boundingBox, text)
            }
            // Vision's boxes start at the bottom left: top lines have the largest y.
            let sorted = pieces.sorted { $0.box.midY > $1.box.midY }
            var lines: [[(box: CGRect, text: String)]] = []
            for piece in sorted {
                if let last = lines.last?.first, abs(last.box.midY - piece.box.midY) < min(last.box.height, piece.box.height) / 2 {
                    lines[lines.count - 1].append(piece)
                } else {
                    lines.append([piece])
                }
            }
            return lines.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
                .joined(separator: "\n")
        }.value
    }

    /// Developer check: --ocr-check <image> <out.txt>.
    static func check(_ image: URL, writeTo out: URL, languages: [String]) {
        Task { @MainActor in
            let text = await recognize(image, languages: recognitionLanguages(languages))
            try? text.write(to: out, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
