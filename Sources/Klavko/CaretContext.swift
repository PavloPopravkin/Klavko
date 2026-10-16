import ApplicationServices

/// Reads the text right before the caret in the focused text field, via Accessibility.
/// Used only as context (is this the start of a sentence? is the caret inside a word?), never stored or sent anywhere.
enum CaretContext {
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        // Don't let a slow or hung app stall typing.
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }()

    /// Up to `limit` characters right after the caret (or the selection); nil if the app doesn't tell.
    static func textAfterCaret(limit: Int = 1) -> String? {
        guard let (element, selection) = focusedSelection() else { return nil }
        var wanted = CFRange(location: selection.location + selection.length, length: limit)
        guard let axRange = AXValueCreate(.cfRange, &wanted) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         axRange, &text) == .success else { return nil }
        return text as? String
    }

    private static func focusedSelection() -> (AXUIElement, CFRange)? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) else { return nil }
        return (element, selection)
    }

    /// Up to `limit` characters before the caret; "" at the very start; nil if the app doesn't tell.
    static func textBeforeCaret(limit: Int = 60) -> String? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) else { return nil }

        let start = max(0, selection.location - limit)
        let length = selection.location - start
        if length <= 0 { return "" }

        var wanted = CFRange(location: start, length: length)
        if let axRange = AXValueCreate(.cfRange, &wanted) {
            var text: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                          axRange, &text) == .success,
               let string = text as? String {
                return string
            }
        }
        // Some apps only expose the whole value.
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let string = value as? String else { return nil }
        let utf16 = Array(string.utf16)
        guard selection.location <= utf16.count else { return nil }
        return String(decoding: utf16[start..<selection.location], as: UTF16.self)
    }
}
