import AppKit
import KlavkoCore
import SwiftUI

/// "AI actions on the selection": copies the selected text, offers actions in a small panel near the
/// mouse, sends the chosen one to Claude and pastes the result back over the selection.
@MainActor
final class AIAssistant: ObservableObject {
    enum Stage: Equatable {
        case choose
        case working(String)
        case result(String)
        case failed(String)
        case noSelection
    }

    @Published private(set) var stage: Stage = .choose
    @Published private(set) var selectedText = ""
    @Published var customInstruction = ""

    var actions: () -> [AIAction] = { AIAction.defaults }
    var model: () -> AIModel = { .opus }
    var openSettings: () -> Void = {}

    private var panel: NSPanel?
    private var request: Task<Void, Never>?

    func start() {
        close()
        SelectionConverter.copySelection { [weak self] text in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.selectedText = text
                    self.stage = .choose
                } else {
                    self.selectedText = ""
                    self.stage = .noSelection
                }
                self.showPanel()
            }
        }
    }

    func run(_ action: AIAction) {
        run(title: action.title, instruction: action.instruction)
    }

    func runCustom() {
        let instruction = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        run(title: instruction, instruction: instruction)
    }

    func backToActions() {
        request?.cancel()
        stage = .choose
    }

    /// Puts the result in place of the selection.
    func replace() {
        guard case .result(let text) = stage else { return }
        close()
        // The other app gets its keyboard focus back once the panel is gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { SelectionConverter.paste(text) }
    }

    func copyResult() {
        guard case .result(let text) = stage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        close()
    }

    func close() {
        request?.cancel()
        request = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func run(title: String, instruction: String) {
        request?.cancel()
        stage = .working(title)
        let text = selectedText
        let model = model()
        request = Task { [weak self] in
            do {
                let result = try await ClaudeClient.edit(text: text, instruction: instruction,
                                                         model: model, apiKey: Keychain.apiKey())
                guard !Task.isCancelled else { return }
                self?.stage = .result(result)
                Log.engine.notice("AI action done with \(model.rawValue, privacy: .public)")
            } catch {
                guard !Task.isCancelled else { return }
                self?.stage = .failed(error.localizedDescription)
                Log.engine.error("AI action failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Developer check of the panel's look: renders it at each stage with sample text into PNG files.
    func snapshots(to directory: URL) {
        selectedText = "Привіт! Хотів спитати, чи зможеш ти завтра заскочити до офісу о десятій?"
        let stages: [(String, Stage)] = [
            ("choose", .choose), ("working", .working("Покращити стиль")),
            ("result", .result("Привіт! Чи зможеш завтра о десятій зайти до офісу?")),
            ("failed", .failed(ClaudeClient.Failure.noKey.localizedDescription)),
        ]
        for (name, stage) in stages {
            self.stage = stage
            let view = NSHostingView(rootView: AIPanelView(assistant: self))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("ai-\(name).png"))
        }
    }

    private func showPanel() {
        let controller = NSHostingController(rootView: AIPanelView(assistant: self))
        controller.sizingOptions = [.preferredContentSize]
        let panel = AIPanel(contentViewController: controller)
        panel.styleMask = [.nonactivatingPanel, .titled, .fullSizeContentView, .closable]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onClose = { [weak self] in self?.close() }
        position(panel)
        // Takes keystrokes (digits, Return, Esc, a custom instruction) without activating Klavko,
        // so the app with the selection stays active and gets the result.
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// Just below and right of the mouse pointer, kept on screen.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)
        if let frame = screen?.visibleFrame {
            origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
            origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }
}

private final class AIPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func close() {
        super.close()
        onClose?()
    }
}

private struct AIPanelView: View {
    @ObservedObject var assistant: AIAssistant

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Klavko · ШІ").font(.headline)
                Spacer()
                if !assistant.selectedText.isEmpty {
                    Text("\(assistant.selectedText.count) симв.").font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(width: 440)
    }

    @ViewBuilder private var content: some View {
        switch assistant.stage {
        case .noSelection:
            Text("Спершу виділіть текст, потім натисніть гарячу клавішу.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Закрити") { assistant.close() }.keyboardShortcut(.cancelAction)
            }

        case .choose:
            Text(assistant.selectedText)
                .lineLimit(2)
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(assistant.actions().prefix(9).enumerated()), id: \.element.id) { index, action in
                    Button {
                        assistant.run(action)
                    } label: {
                        HStack {
                            Text(action.title).foregroundStyle(.primary)
                            Spacer()
                            Text("⌘\(index + 1)").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            HStack {
                TextField("", text: $assistant.customInstruction, prompt: Text("Своя інструкція, наприклад «зроби список»"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { assistant.runCustom() }
                Button("Виконати") { assistant.runCustom() }
                    .disabled(assistant.customInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Text("Текст надсилається в Anthropic лише після вибору дії.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Скасувати") { assistant.close() }.keyboardShortcut(.cancelAction)
            }

        case .working(let title):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("\(title)…")
            }
            HStack {
                Spacer()
                Button("Скасувати") { assistant.close() }.keyboardShortcut(.cancelAction)
            }

        case .result(let text):
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            HStack {
                Button("Інша дія") { assistant.backToActions() }
                Spacer()
                Button("Скасувати") { assistant.close() }.keyboardShortcut(.cancelAction)
                Button("Копіювати") { assistant.copyResult() }
                Button("Замінити") { assistant.replace() }.keyboardShortcut(.defaultAction)
            }

        case .failed(let message):
            Text(message).foregroundStyle(.red)
            HStack {
                Button("Налаштування…") {
                    assistant.close()
                    assistant.openSettings()
                }
                Spacer()
                Button("Інша дія") { assistant.backToActions() }
                Button("Закрити") { assistant.close() }.keyboardShortcut(.cancelAction)
            }
        }
    }
}
