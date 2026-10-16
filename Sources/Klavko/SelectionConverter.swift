import AppKit
import Carbon
import KlavkoCore

/// Changes the selected text in the frontmost app: copy, transform, paste, select it again
/// (so the same hotkey can be pressed again), restore the clipboard.
enum SelectionConverter {
    private static let keyC: CGKeyCode = 8
    private static let keyV: CGKeyCode = 9
    private static let leftArrow: CGKeyCode = 123

    /// Retypes the selection in the other layout ("ghbdsn" → "привіт") and switches to that layout.
    static func convert(layouts: [(source: TISInputSource, map: LayoutMap)], onConverted: @escaping () -> Void) {
        var target: TISInputSource?
        transform({ text in
            guard let from = LayoutConverter.sourceLayout(of: text, among: layouts.map(\.map)),
                  let to = layouts.first(where: { $0.map.language != from.language }) else { return nil }
            target = to.source
            Log.engine.notice("Converting selection \(from.language, privacy: .public)→\(to.map.language, privacy: .public), \(text.count) chars")
            return LayoutConverter.convert(text, from: from, to: to.map)
        }, onDone: {
            if let target { SystemLayouts.select(target) }
            onConverted()
        })
    }

    /// Replaces the selection with `change(selection)`; nil or the same text leaves it alone.
    static func transform(_ change: @escaping (String) -> String?, onDone: @escaping () -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let countBeforeCopy = pasteboard.changeCount

        TextInjector.pressKey(keyC, flags: .maskCommand)

        // Give the app time to put the selection on the clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard pasteboard.changeCount != countBeforeCopy,
                  let text = pasteboard.string(forType: .string), !text.isEmpty,
                  let changed = change(text), changed != text
            else {
                Log.engine.notice("Selection left alone: nothing selected or nothing to change")
                if pasteboard.changeCount != countBeforeCopy { restore(saved, to: pasteboard) }
                return
            }

            pasteboard.clearContents()
            pasteboard.setString(changed, forType: .string)
            let countAfterWrite = pasteboard.changeCount

            TextInjector.pressKey(keyV, flags: .maskCommand)
            onDone()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                // Select the pasted text again, so pressing the hotkey again goes on (or switches back).
                for _ in 0..<changed.count { TextInjector.pressKey(leftArrow, flags: .maskShift) }
            }
            // Restore the user's clipboard once the app has pasted, unless they copied something new.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if pasteboard.changeCount == countAfterWrite { restore(saved, to: pasteboard) }
            }
        }
    }

    /// Copies the selection and hands over its text (nil if nothing is selected); the clipboard is restored.
    static func copySelection(_ completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let countBeforeCopy = pasteboard.changeCount
        TextInjector.pressKey(keyC, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard pasteboard.changeCount != countBeforeCopy else { return completion(nil) }
            let text = pasteboard.string(forType: .string)
            restore(saved, to: pasteboard)
            completion(text)
        }
    }

    /// Pastes `text` over the selection in the frontmost app; the clipboard is restored afterwards.
    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let countAfterWrite = pasteboard.changeCount
        TextInjector.pressKey(keyV, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if pasteboard.changeCount == countAfterWrite { restore(saved, to: pasteboard) }
        }
    }

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private static func snapshot(_ pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshot.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
