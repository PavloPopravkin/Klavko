import Foundation

/// Modifier keys, in the order macOS displays them (⌃⌥⇧⌘), then Fn (🌐).
public enum ModifierKey: String, Codable, CaseIterable, Sendable {
    case control, option, shift, command, function

    public var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        case .function: "fn"
        }
    }

    /// Left and right physical keys.
    public init?(keyCode: UInt16) {
        switch keyCode {
        case 59, 62: self = .control
        case 58, 61: self = .option
        case 56, 60: self = .shift
        case 55, 54: self = .command
        case 63: self = .function
        default: return nil
        }
    }

    /// Canonical order, so equal sets compare and display the same.
    public static func sorted(_ set: Set<ModifierKey>) -> [ModifierKey] {
        allCases.filter(set.contains)
    }
}

/// A user-assignable shortcut.
public enum Shortcut: Codable, Hashable, Sendable {
    /// Modifiers pressed together and released with no other key, e.g. ⌥⌘ or a double ⇧⇧.
    case modifierTap(modifiers: [ModifierKey], double: Bool)
    /// A regular key with modifiers, e.g. ⌃⇧Space.
    case combo(keyCode: UInt16, modifiers: [ModifierKey])

    public init(keyCode: UInt16, modifiers: Set<ModifierKey>) {
        self = .combo(keyCode: keyCode, modifiers: ModifierKey.sorted(modifiers))
    }

    public init(modifiers: Set<ModifierKey>, double: Bool) {
        self = .modifierTap(modifiers: ModifierKey.sorted(modifiers), double: double)
    }

    public func matches(keyCode: UInt16, modifiers: Set<ModifierKey>) -> Bool {
        self == Shortcut(keyCode: keyCode, modifiers: modifiers)
    }

    public func matches(_ tap: ModifierTap) -> Bool {
        switch tap {
        case .single(let modifiers): self == Shortcut(modifiers: modifiers, double: false)
        case .double(let modifiers): self == Shortcut(modifiers: modifiers, double: true)
        }
    }

    /// Pieces for keycap-style display: ["двічі", "⌥", "⌘"], ["⌃", "⇧", "Space"].
    public func parts(layout: LayoutMap?) -> [String] {
        switch self {
        case .modifierTap(let modifiers, let double):
            return (double ? ["двічі"] : []) + modifiers.map(\.symbol)
        case .combo(let keyCode, let modifiers):
            return modifiers.map(\.symbol) + [KeyNames.name(for: keyCode, layout: layout)]
        }
    }

    /// "⇧⇧", "двічі ⌥⌘", "⌥⌘", "⌃⇧Space".
    public func displayName(layout: LayoutMap?) -> String {
        switch self {
        case .modifierTap(let modifiers, true) where modifiers.count == 1:
            return modifiers[0].symbol + modifiers[0].symbol
        case .modifierTap(let modifiers, true):
            return "двічі " + modifiers.map(\.symbol).joined()
        default:
            return parts(layout: layout).joined()
        }
    }
}

public enum HotkeyAction: String, Codable, CaseIterable, Sendable {
    case convertWord, convertText, undo, changeCase, translate, clipboard, voice

    public var title: String {
        switch self {
        case .convertWord: "Змінити розкладку слова"
        case .convertText: "Змінити розкладку виділеного або набраного"
        case .undo: "Скасувати або повернути виправлення"
        case .changeCase: "Змінити регістр (слово або виділене)"
        case .translate: "Перекласти виділене (укр. ↔ англ.)"
        case .clipboard: "Історія буфера обміну"
        case .voice: "Голосовий ввід (почати / вставити)"
        }
    }

    public var defaultShortcut: Shortcut? {
        switch self {
        case .convertWord: Shortcut(modifiers: [.shift], double: true)
        case .convertText: Shortcut(modifiers: [.option], double: true)
        case .undo: nil
        case .changeCase: nil
        case .translate: Shortcut(modifiers: [.command], double: true)
        case .clipboard: Shortcut(keyCode: 9, modifiers: [.option, .command])  // ⌥⌘V
        case .voice: Shortcut(modifiers: [.function], double: false)
        }
    }
}

/// When to check a finished word.
public enum SwitchTrigger: String, Codable, CaseIterable, Sendable {
    case space, tab, enter, punctuation

    public var title: String {
        switch self {
        case .space: "Space"
        case .tab: "Tab"
        case .enter: "Enter"
        case .punctuation: ", . ! ?"
        }
    }
}

public enum KeyNames {
    private static let special: [UInt16: String] = [
        49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]

    public static func name(for keyCode: UInt16, layout: LayoutMap?) -> String {
        special[keyCode]
            ?? layout?.character(for: Keystroke(keyCode: keyCode))?.uppercased()
            ?? "#\(keyCode)"
    }
}

public enum ModifierTap: Equatable, Sendable {
    case single(Set<ModifierKey>)
    case double(Set<ModifierKey>)
}

/// Recognizes modifier-only gestures: a chord pressed and released alone (⌥⌘),
/// and the same chord tapped twice quickly (⇧⇧).
public struct ModifierTapDetector {
    public var maxChordDuration: TimeInterval = 0.6
    public var maxInterval: TimeInterval = 0.5

    private var chord: Set<ModifierKey> = []
    private var startedAt: TimeInterval?
    private var interrupted = false
    private var lastTap: (chord: Set<ModifierKey>, at: TimeInterval)?

    public init() {}

    /// Feed the set of held modifiers after every modifier change.
    /// Returns [.single] when a chord is released, plus .double when it was the second quick tap.
    public mutating func modifiersChanged(_ active: Set<ModifierKey>, at time: TimeInterval) -> [ModifierTap] {
        if !active.isEmpty {
            if startedAt == nil {
                startedAt = time
                chord = active
                interrupted = false
            } else {
                chord.formUnion(active)
            }
            return []
        }

        guard let start = startedAt else { return [] }
        startedAt = nil
        guard !interrupted, time - start < maxChordDuration else {
            lastTap = nil
            return []
        }
        var taps: [ModifierTap] = [.single(chord)]
        if let last = lastTap, last.chord == chord, time - last.at < maxInterval {
            taps.append(.double(chord))
            lastTap = nil
        } else {
            lastTap = (chord, time)
        }
        return taps
    }

    /// A regular key, mouse click or Caps Lock cancels the gesture in progress.
    public mutating func interrupt() {
        interrupted = true
        lastTap = nil
    }
}
