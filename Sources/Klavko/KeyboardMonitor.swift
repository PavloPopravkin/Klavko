import CoreGraphics
import Foundation

/// Global keyboard/mouse event tap. Needs the Accessibility permission.
final class KeyboardMonitor {
    /// Return false to swallow the event.
    typealias Handler = (CGEventType, CGEvent) -> Bool

    private let handler: Handler
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }

        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.process(type, event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        Log.monitor.notice("Event tap started")
        return true
    }

    /// Watchdog: macOS may disable the tap and only tell us on the next event.
    func ensureEnabled() {
        guard let tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.monitor.notice("Event tap was disabled; re-enabled by watchdog")
    }

    // MARK: - Keys held during an injection

    private var heldKeys: [CGEvent] = []

    private func hold(_ event: CGEvent) {
        if heldKeys.isEmpty {
            // If a sentinel never comes back, don't keep the user's keys forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !heldKeys.isEmpty else { return }
                Log.monitor.notice("Injection sentinel lost; releasing held keys")
                TextInjector.forgetPendingSentinels()
                releaseHeldKeys()
            }
        }
        heldKeys.append(event)
    }

    /// Re-posts the held keys in order; they go through the tap again and are handled as usual.
    private func releaseHeldKeys() {
        guard !heldKeys.isEmpty else { return }
        let keys = heldKeys
        heldKeys = []
        Log.monitor.notice("Released \(keys.count) key(s) typed during a replacement")
        for key in keys { key.post(tap: .cghidEventTap) }
    }

    private func process(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap whose callback is too slow; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.monitor.notice("Event tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        // The end of one of our injections: keys held meanwhile can go now.
        if marker == TextInjector.sentinelMarker {
            TextInjector.sentinelArrived()
            if !TextInjector.isInjecting { releaseHeldKeys() }
            return nil
        }
        // Our own synthetic keystrokes.
        if marker == TextInjector.marker {
            return Unmanaged.passUnretained(event)
        }
        // A key typed while our text is still on its way: hold it, so it lands after our text.
        if type == .keyDown && TextInjector.isInjecting, let copy = event.copy() {
            hold(copy)
            return nil
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let pass = handler(type, event)
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        if elapsedMs > 50 {
            Log.monitor.notice("Slow event handling: \(elapsedMs) ms")
        }
        return pass ? Unmanaged.passUnretained(event) : nil
    }
}
