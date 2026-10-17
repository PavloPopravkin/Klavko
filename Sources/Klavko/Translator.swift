import AppKit
import KlavkoCore
import SwiftUI
import Translation

/// "Translate the selection": copies the selected text, translates it Ukrainian ↔ English with the
/// translator built into macOS (on this Mac, no account or key) and shows the result in a small panel
/// near the mouse; Return puts it in place of the selection, ⌘C copies it.
@MainActor
final class Translator: ObservableObject {
    enum Stage: Equatable {
        case working
        case downloading
        case result(String)
        case failed(String)
        case noSelection
    }

    /// One translation request; a new id makes the panel run it even for the same languages.
    struct Job: Equatable {
        let id: Int
        let text: String
        let direction: TranslationDirection
    }

    @Published private(set) var stage: Stage = .working
    @Published private(set) var job: Job?

    private var panel: NSPanel?
    /// The mouse position the panel opened at; it stays next to it as its content grows.
    private var anchor = NSPoint.zero
    private var resizeObserver: NSObjectProtocol?
    /// Where the selection came from when Accessibility gave it directly (no clipboard used).
    private var selection: SelectionConverter.Selection?
    private var nextID = 0
    /// The app with the selection, to give focus back to if a language download brought Klavko forward.
    private var sourceApp: NSRunningApplication?

    func start() {
        close()
        sourceApp = NSWorkspace.shared.frontmostApplication
        anchor = NSEvent.mouseLocation
        // Without the clipboard where the app allows it; ⌘C (clipboard restored) elsewhere.
        if let selection = SelectionConverter.accessibleSelection() {
            self.selection = selection
            translate(selection.text, TranslationDirection(for: selection.text))
            showPanel()
            return
        }
        selection = nil
        SelectionConverter.copySelection { [weak self] text in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.translate(text, TranslationDirection(for: text))
                } else {
                    self.job = nil
                    self.stage = .noSelection
                }
                self.showPanel()
            }
        }
    }

    /// The same text the other way round, for when the guess was wrong.
    func swapDirection() {
        guard let job else { return }
        translate(job.text, job.direction.reversed)
    }

    /// Puts the result in place of the selection.
    func replace() {
        guard case .result(let text) = stage else { return }
        let app = sourceApp
        let selection = selection
        close()
        app?.activate()
        if let selection, selection.replace(with: text) { return }
        // The other app gets its keyboard focus back once the panel is gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { SelectionConverter.paste(text) }
    }

    func copyResult() {
        guard case .result(let text) = stage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let app = sourceApp
        close()
        app?.activate()
    }

    func close() {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        panel?.orderOut(nil)
        panel = nil
        job = nil
    }

    private func translate(_ text: String, _ direction: TranslationDirection) {
        nextID += 1
        job = Job(id: nextID, text: text, direction: direction)
        stage = .working
    }

    /// Called from the panel's translation task with the session macOS made for `job`.
    @available(macOS 15.0, *)
    nonisolated func run(_ job: Job, session: TranslationSession) async {
        let source = Locale.Language(identifier: job.direction.source)
        let target = Locale.Language(identifier: job.direction.target)
        if await LanguageAvailability().status(from: source, to: target) != .installed {
            // macOS asks to download the two languages once; its dialog needs Klavko in front.
            await MainActor.run {
                stage = .downloading
                NSApp.activate()
            }
        }
        let lines = TranslationLines(job.text)
        do {
            let requests = lines.toTranslate.map { TranslationSession.Request(sourceText: $0) }
            let responses = try await session.translations(from: requests)
            let result = lines.assemble(responses.map(\.targetText))
            await finish(job, .result(result))
            Log.engine.notice("Translated \(job.direction.source, privacy: .public) → \(job.direction.target, privacy: .public)")
        } catch {
            await finish(job, .failed(Self.message(for: error)))
            Log.engine.error("Translation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finish(_ finished: Job, _ stage: Stage) {
        guard job?.id == finished.id else { return }
        self.stage = stage
        // Back to the app with the selection, so Return / ⌘C here still lead there.
        if NSApp.isActive { sourceApp?.activate() }
        panel?.makeKeyAndOrderFront(nil)
    }

    @available(macOS 15.0, *)
    private nonisolated static func message(for error: Error) -> String {
        switch error {
        case TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage:
            "Перекладач macOS не підтримує цю пару мов."
        case TranslationError.nothingToTranslate:
            "Немає що перекладати."
        default:
            "Не вдалося перекласти: \(error.localizedDescription)"
        }
    }

    /// Developer check: --translate-check <text> <out.txt> translates without a selection and writes the result.
    func check(_ text: String, writeTo url: URL) {
        sourceApp = nil
        anchor = NSEvent.mouseLocation
        translate(text, TranslationDirection(for: text))
        showPanel()
        Task { @MainActor in
            for _ in 0..<600 {
                switch stage {
                case .result(let result), .failed(let result):
                    try? result.write(to: url, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                    return
                default:
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            try? "timeout".write(to: url, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private func showPanel() {
        let controller = NSHostingController(rootView: TranslatorPanelView(translator: self))
        controller.sizingOptions = [.preferredContentSize]
        let panel = TranslatorPanel(contentViewController: controller)
        panel.styleMask = [.nonactivatingPanel, .titled, .fullSizeContentView, .closable]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onClose = { [weak self] in self?.close() }
        place(panel)
        // The result is taller than "Translating…": keep the grown panel next to the mouse and on screen.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel else { return }
                self.place(panel)
            }
        }
        // Takes Return / ⌘C / Esc without activating Klavko, so the app with the selection stays active.
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// Below and right of the mouse pointer; above it when there is no room below; always on screen.
    private func place(_ panel: NSPanel) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        var origin = NSPoint(x: anchor.x + 12, y: anchor.y - size.height - 12)
        if let frame = screen?.visibleFrame {
            if origin.y < frame.minY + 8 { origin.y = anchor.y + 12 }
            origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
            origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
        }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}

private final class TranslatorPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func close() {
        super.close()
        onClose?()
    }
}

private struct TranslatorPanelView: View {
    @ObservedObject var translator: Translator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Klavko · Переклад").font(.headline)
                Spacer()
                if let job = translator.job {
                    Button {
                        translator.swapDirection()
                    } label: {
                        Text(job.direction.title)
                    }
                    .buttonStyle(.borderless)
                    .help("Перекласти в інший бік")
                }
            }
            content
        }
        .padding(16)
        .frame(width: 440)
        .modifier(TranslationRunner(translator: translator))
    }

    @ViewBuilder private var content: some View {
        if #unavailable(macOS 15.0) {
            Text("Переклад працює на macOS 15 Sequoia і новіших.")
                .foregroundStyle(.secondary)
            closeRow
        } else {
            switch translator.stage {
            case .noSelection:
                Text("Спершу виділіть текст, потім натисніть гарячу клавішу.")
                    .foregroundStyle(.secondary)
                closeRow

            case .working, .downloading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(translator.stage == .downloading
                         ? "Завантажую мови для перекладу (один раз)…" : "Перекладаю…")
                }
                closeRow

            case .result(let text):
                ScrollView {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Перекладач macOS, на цьому Mac").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Копіювати") { translator.copyResult() }
                        .keyboardShortcut("c", modifiers: .command)
                    Button("Замінити") { translator.replace() }
                        .keyboardShortcut(.defaultAction)
                }

            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
                closeRow
            }
        }
    }

    private var closeRow: some View {
        HStack {
            Spacer()
            Button("Закрити") { translator.close() }.keyboardShortcut(.cancelAction)
        }
    }
}

/// Runs the current job through the macOS translator (the session only comes from SwiftUI before macOS 26).
private struct TranslationRunner: ViewModifier {
    @ObservedObject var translator: Translator

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(SessionRunner(translator: translator))
        } else {
            content
        }
    }
}

@available(macOS 15.0, *)
private struct SessionRunner: ViewModifier {
    @ObservedObject var translator: Translator
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { [translator] session in
                guard let job = await MainActor.run(body: { translator.job }) else { return }
                await translator.run(job, session: session)
            }
            .onAppear { update(for: translator.job) }
            .onChange(of: translator.job) { _, job in update(for: job) }
    }

    private func update(for job: Translator.Job?) {
        guard let job else { return }
        let source = Locale.Language(identifier: job.direction.source)
        let target = Locale.Language(identifier: job.direction.target)
        if configuration?.source == source && configuration?.target == target {
            configuration?.invalidate()  // Same languages, new text: run again.
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }
}
