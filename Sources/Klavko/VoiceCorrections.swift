import AppKit
import KlavkoCore
import SwiftUI

/// After dictation, notices when the user fixes a dictated word in the same field ("адра" → "ADRA"),
/// so Klavko can offer to spell it that way next time. Reads the field through Accessibility once the
/// user pauses typing (and right before Return, which may send the message and empty the field).
@MainActor
final class VoiceCorrectionWatcher {
    /// Spellings already known: not offered again.
    var known: () -> [Replacement] = { [] }
    var onFound: ([Replacement]) -> Void = { _ in }

    private var inserted: String?
    private var element: AXUIElement?
    private var expires = Date.distantPast
    private var pending: DispatchWorkItem?

    /// Watch the focused field for two minutes after `text` was dictated into it.
    func watch(inserted text: String) {
        stop()
        guard let focused = Self.focusedElement() else { return }
        inserted = text
        element = focused
        expires = Date().addingTimeInterval(120)
    }

    /// The user pressed a key: look at the field once they pause.
    func userTyped() {
        guard inserted != nil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkNow() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func checkNow() {
        pending?.cancel()
        pending = nil
        guard let inserted, let element else { return }
        guard Date() < expires, let focused = Self.focusedElement(), CFEqual(focused, element) else {
            return stop()
        }
        guard let around = Self.textAroundCaret(in: element, span: inserted.utf16.count + 200) else { return }
        let known = known()
        let found = VoiceVocabulary.corrections(inserted: inserted, now: around).filter { pair in
            !known.contains { $0.from.lowercased() == pair.from.lowercased() && $0.to == pair.to }
        }
        guard !found.isEmpty else { return }
        Log.engine.notice("Dictated text corrected: \(found.count) word(s)")
        stop()
        onFound(found)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        inserted = nil
        element = nil
    }

    private static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    /// The field's text from `span` characters before the caret to `span` after (the dictated text is there).
    private static func textAroundCaret(in element: AXUIElement, span: Int) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let whole = text as NSString
        var caret = whole.length
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) { caret = min(range.location, whole.length) }
        }
        let start = max(0, caret - span)
        let end = min(whole.length, caret + span)
        return whole.substring(with: NSRange(location: start, length: end - start))
    }
}

/// "Remember this spelling?" — a glowing card at the bottom of the screen with a bar that runs out in
/// five seconds; ignored, nothing is saved. Never activates Klavko, so typing goes on.
@MainActor
final class VoiceLearnPrompt {
    static let duration: TimeInterval = 5

    private var panel: NSPanel?
    private var autoClose: DispatchWorkItem?

    func show(_ corrections: [Replacement], onConfirm: @escaping () -> Void) {
        close()
        let view = VoiceLearnView(corrections: corrections,
                                  onConfirm: { [weak self] in onConfirm(); self?.close() },
                                  onDismiss: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel = LearnPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: (frame.midX - size.width / 2).rounded(), y: frame.minY + 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }

    func close() {
        autoClose?.cancel()
        autoClose = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Developer check of the card's look.
    static func snapshot(to url: URL) {
        let view = VoiceLearnView(corrections: [Replacement(from: "адра", to: "ADRA")],
                                  onConfirm: {}, onDismiss: {}, frozenProgress: 0.6)
            .background(Color(white: 0.9))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

private final class LearnPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct VoiceLearnView: View {
    let corrections: [Replacement]
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    var frozenProgress: CGFloat?

    @State private var progress: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Запам’ятати для голосового вводу?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    ForEach(corrections, id: \.self) { pair in
                        HStack(spacing: 6) {
                            Text(pair.from).strikethrough().foregroundStyle(.white.opacity(0.55))
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Neon.cyan)
                            Text(pair.to).fontWeight(.semibold).foregroundStyle(.white)
                        }
                        .font(.system(size: 14))
                    }
                }
                Spacer(minLength: 12)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Не запам’ятовувати")
            }
            HStack(spacing: 10) {
                // Time left to confirm.
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule()
                            .fill(LinearGradient(colors: [Neon.cyan, Neon.sky, Neon.blue],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * (frozenProgress ?? progress))
                            .shadow(color: Neon.sky.opacity(0.9), radius: 3)
                    }
                }
                .frame(height: 4)
                Button(action: onConfirm) {
                    Text("Підтвердити")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(LinearGradient(colors: [Neon.sky, Neon.blue],
                                                                  startPoint: .top, endPoint: .bottom)))
                        .shadow(color: Neon.sky.opacity(0.7), radius: 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Neon.navy).opacity(0.95))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Neon.rim, lineWidth: 1).opacity(0.6))
        .shadow(color: Neon.blue.opacity(0.45), radius: 12)
        .padding(18)  // room for the glow
        .onAppear {
            withAnimation(.linear(duration: VoiceLearnPrompt.duration)) { progress = 0 }
        }
    }
}
