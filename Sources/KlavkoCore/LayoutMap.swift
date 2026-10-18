import Foundation

/// A physical key press: which key and which modifiers affect the produced character.
public struct Keystroke: Hashable, Sendable {
    public let keyCode: UInt16
    public let shift: Bool
    public let capsLock: Bool

    public init(keyCode: UInt16, shift: Bool = false, capsLock: Bool = false) {
        self.keyCode = keyCode
        self.shift = shift
        self.capsLock = capsLock
    }
}

/// Characters a keyboard layout produces for each keystroke.
public struct LayoutMap: Sendable {
    /// Input source ID, e.g. "com.apple.keylayout.Ukrainian-PC".
    public let id: String
    /// Primary language of the layout, two letters: "uk", "en", "ru", "de"…
    public let language: String
    /// The alphabet its letter keys type.
    public let script: Script
    private let table: [Keystroke: String]
    /// Character -> simplest keystroke producing it (no Caps Lock, Shift only when needed).
    private let reverse: [String: Keystroke]

    public init(id: String, language: String, table: [Keystroke: String]) {
        self.id = id
        self.language = language
        self.table = table

        var reverse: [String: Keystroke] = [:]
        for (keystroke, character) in table where !keystroke.capsLock {
            if let existing = reverse[character], Self.isSimpler(existing, than: keystroke) { continue }
            reverse[character] = keystroke
        }
        self.reverse = reverse

        var counts: [Script: Int] = [:]
        for (keystroke, character) in table where !keystroke.shift && !keystroke.capsLock {
            if let script = Script(of: character) { counts[script, default: 0] += 1 }
        }
        self.script = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key.rawValue > $1.key.rawValue }?.key ?? .other
    }

    /// Unshifted beats shifted; otherwise the lower key code wins (deterministic).
    private static func isSimpler(_ a: Keystroke, than b: Keystroke) -> Bool {
        a.shift != b.shift ? !a.shift : a.keyCode < b.keyCode
    }

    /// Letters the layout types without Shift or Caps Lock, lowercase.
    public var lowercaseLetters: Set<Character> {
        Set(table.compactMap { keystroke, character in
            !keystroke.shift && !keystroke.capsLock && TextRules.isWordCharacter(character)
                ? character.lowercased().first : nil
        })
    }

    public func character(for keystroke: Keystroke) -> String? {
        table[keystroke]
    }

    public func keystroke(for character: String) -> Keystroke? {
        reverse[character]
    }

    /// Text the keystrokes produce in this layout, or nil if a key has no character.
    public func render(_ keystrokes: [Keystroke]) -> String? {
        var result = ""
        for keystroke in keystrokes {
            guard let character = table[keystroke] else { return nil }
            result += character
        }
        return result
    }

    /// True when the key produces a letter or an apostrophe in this layout.
    public func isWordCharacter(_ keystroke: Keystroke) -> Bool {
        guard let character = table[keystroke] else { return false }
        return TextRules.isWordCharacter(character)
    }
}

/// The alphabet of a letter. Wrong-layout typing is mostly typing in one alphabet while meaning another.
public enum Script: String, Sendable {
    case latin, cyrillic, greek, hebrew, arabic, other

    /// nil for anything but a single letter.
    public init?(of text: String) {
        guard text.count == 1, let character = text.first, character.isLetter,
              let value = character.unicodeScalars.first?.value else { return nil }
        switch value {
        case 0x0041...0x024F, 0x1E00...0x1EFF: self = .latin
        case 0x0400...0x052F: self = .cyrillic
        case 0x0370...0x03FF, 0x1F00...0x1FFF: self = .greek
        case 0x0590...0x05FF: self = .hebrew
        case 0x0600...0x06FF, 0x0750...0x077F: self = .arabic
        default: self = .other
        }
    }
}

public enum TextRules {
    static let apostrophes: Set<Character> = ["'", "’", "ʼ"]

    public static func isWordCharacter(_ string: String) -> Bool {
        guard string.count == 1, let character = string.first else { return false }
        return character.isLetter || apostrophes.contains(character)
    }

    /// "pрuвіт": Latin and Cyrillic letters in one word, usually a half-converted or deliberate mix.
    public static func mixesScripts(_ text: String) -> Bool {
        var latin = false, cyrillic = false
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            switch scalar.value {
            case 0x0041...0x024F: latin = true
            case 0x0400...0x04FF: cyrillic = true
            default: break
            }
        }
        return latin && cyrillic
    }

    /// "NATO", "ЗСУ": at least two letters, all capitals.
    public static func isAllCaps(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    /// Strips leading/trailing non-letters and normalizes apostrophes to "'".
    /// "привіт." -> "привіт", "м’ята" -> "м'ята", "'quoted'" -> "quoted"
    public static func coreWord(_ text: String) -> String {
        let normalized = String(text.map { apostrophes.contains($0) ? "'" : $0 })
        let trimmed = normalized.drop { !$0.isLetter }.reversed().drop { !$0.isLetter }.reversed()
        return String(trimmed)
    }
}
