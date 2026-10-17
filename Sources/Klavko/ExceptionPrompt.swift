import AppKit
import KlavkoCore
import SwiftUI

/// A small floating card in the top-right corner that offers to add a word to the exceptions.
/// It never activates Klavko, so typing in the current app continues undisturbed.
@MainActor
final class ExceptionPrompt {
    private var panel: NSPanel?
    private var autoClose: DispatchWorkItem?

    func show(word: String, onAdd: @escaping () -> Void, onDecline: @escaping () -> Void) {
        close()
        let view = ExceptionPromptView(word: word,
                                       onAdd: { [weak self] in onAdd(); self?.close() },
                                       onDismiss: { [weak self] in onDecline(); self?.close() })
        let hosting = NSHostingView(rootView: view)
        var size = hosting.fittingSize
        if size.width < 100 || size.height < 40 { size = NSSize(width: 300, height: 130) }
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = PromptPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    func close() {
        autoClose?.cancel()
        autoClose = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Accepts clicks on its buttons without activating the app.
private final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ExceptionPromptView: View {
    let word: String
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Klavko")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(tr("Ви вже двічі скасували виправлення слова «\(word)». Додати його до винятків, щоб Klavko більше його не змінював?",
                     "You have undone the fix of “\(word)” twice. Add it to the exceptions so Klavko leaves it alone?"))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Ні", "No"), action: onDismiss)
                Button(tr("Додати", "Add"), action: onAdd)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
