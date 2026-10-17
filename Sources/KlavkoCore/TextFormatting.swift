import Foundation

/// Capital letter at the start of a sentence.
public enum Capitalization {
    /// Words ending in a full stop that don't end a sentence (lowercase, without the dot).
    static let abbreviations: Set<String> = [
        "т.д", "т.п", "т.ч", "див", "напр", "вул", "буд", "кв", "ст", "р", "рр", "грн", "тис", "млн", "млрд",
        "ім", "проф", "акад", "пл", "обл", "м", "с", "смт", "пров", "просп", "доц", "канд", "зам", "тел",
        "e.g", "i.e", "etc", "vs", "mr", "mrs", "ms", "dr", "st", "no", "approx", "fig",
    ]

    /// Whether a letter typed after `before` starts a sentence.
    /// `atFieldStart`: `before` is empty because the caret is at the very start of the text (not just unknown).
    public static func startsSentence(before: String, atFieldStart: Bool) -> Bool {
        if before.isEmpty { return atFieldStart }
        if before.last == "\n" { return true }
        // A sentence mark, then at least one space.
        let afterMark = before.reversed().prefix { $0 == " " || $0 == "\u{00A0}" }
        guard !afterMark.isEmpty else { return false }
        let rest = before.dropLast(afterMark.count)
        if rest.last == "\n" || rest.isEmpty { return rest.isEmpty ? atFieldStart : true }
        guard let mark = rest.last, ".!?".contains(mark) else { return false }
        // "Ну... давай": an ellipsis usually continues the sentence.
        if rest.hasSuffix("..") { return false }
        guard mark == "." else { return true }

        let token = String(rest.dropLast().reversed().prefix { !$0.isWhitespace }.reversed())
        let letters = token.filter(\.isLetter)
        // "т.д.", "U.S.", "google.com.", "3." in a list is fine (it has no letters).
        if letters.count == 1 && !token.contains(where: \.isNumber) { return false }
        if abbreviations.contains(token.lowercased()) { return false }
        if token.contains("@") || token.contains("/") { return false }
        return true
    }
}

/// A text replacement: what is typed and what it becomes.
public struct Replacement: Codable, Hashable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    /// Ends with a letter: a whole word, replaced when the word ends ("сп" → "спасибі").
    /// Otherwise it fires as soon as its last character is typed ("..." → "…").
    public var isWord: Bool { from.last?.isLetter == true }
}

/// Typographic replacements.
public enum Typography {
    /// Fire as soon as typed. Ones starting with "(" only after a space or at the start ("f(c)" in code stays).
    public static let builtIn: [Replacement] = [
        Replacement(from: "...", to: "…"),
        Replacement(from: "(c)", to: "©"), Replacement(from: "(C)", to: "©"),
        Replacement(from: "(r)", to: "®"), Replacement(from: "(R)", to: "®"),
        Replacement(from: "(tm)", to: "™"), Replacement(from: "(TM)", to: "™"),
    ]

    /// The immediate replacement `text` now ends with (the longest one), if any.
    public static func immediateMatch(in text: String, rules: [Replacement]) -> Replacement? {
        rules.filter { rule in
            guard !rule.isWord, !rule.from.isEmpty, text.hasSuffix(rule.from) else { return false }
            if rule.from.first == "(" {
                let before = text.dropLast(rule.from.count).last
                return before == nil || before!.isWhitespace
            }
            return true
        }.max { $0.from.count < $1.from.count }
    }

    /// A whole-word replacement for a finished word, ignoring letter case ("зсу", "Зсу" → "ЗСУ").
    /// An exact match wins if there are rules for several cases.
    public static func wordMatch(_ word: String, rules: [Replacement]) -> Replacement? {
        rules.first { $0.isWord && $0.from == word }
            ?? rules.first { $0.isWord && $0.from.lowercased() == word.lowercased() }
    }

    /// The curly quote for a straight `"` typed after `before`: «» in Ukrainian, “” in English.
    /// Opening at the start, after a space or an opening bracket; closing otherwise — after a word,
    /// a mark, or right after an opening quote (two presses give «»).
    public static func quote(after before: String, language: String) -> Character {
        let opening = before.last.map { $0.isWhitespace || "([{".contains($0) } ?? true
        if language == "uk" { return opening ? "«" : "»" }
        return opening ? "“" : "”"
    }

    /// "слово - " / "слово -- " → "слово — ": how many hyphens (1 or 2) before the Space being typed
    /// form a dash. Not at the start of a line ("- пункт" is a list) or in "--flag".
    public static func dashHyphens(before: String) -> Int {
        for count in [2, 1] {
            let hyphens = String(repeating: "-", count: count)
            guard before.hasSuffix(" " + hyphens) else { continue }
            let rest = before.dropLast(count + 1)
            guard let previous = rest.last, !previous.isWhitespace, previous != "-" else { return 0 }
            return count
        }
        return 0
    }
}

/// Continuing a list when Enter is pressed.
public enum ListContinuation {
    public enum Action: Equatable {
        /// Type this after the line break ("- ", "2. ", "  • ").
        case continueWith(String)
        /// The item is empty: delete these many characters (the marker) instead of a new line.
        case endList(deleting: Int)
    }

    /// What to do on Enter at the end of `line` (the text of the current line before the caret).
    public static func action(for line: String) -> Action? {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let body = line.dropFirst(indent.count)

        var marker: String?
        var next: String?
        if let first = body.first, "-–—•*".contains(first) {
            marker = String(first)
            next = String(first)
        } else {
            let digits = body.prefix(while: \.isNumber)
            if !digits.isEmpty, digits.count <= 3, let number = Int(digits),
               let punctuation = body.dropFirst(digits.count).first, punctuation == "." || punctuation == ")" {
                marker = String(digits) + String(punctuation)
                next = "\(number + 1)\(punctuation)"
            }
        }
        guard let marker, let next else { return nil }
        let afterMarker = body.dropFirst(marker.count)
        // A marker must be followed by a space: "-5" or "1.5" isn't a list.
        guard let space = afterMarker.first, space == " " || space == "\t" else { return nil }
        let text = afterMarker.drop { $0 == " " || $0 == "\t" }
        if text.isEmpty { return .endList(deleting: line.count) }
        return .continueWith(indent + next + " ")
    }
}

/// Case changes for a hotkey, in a cycle: малі → Перша велика → ВЕЛИКІ → малі.
public enum CaseCycle {
    public static func next(_ text: String) -> String {
        let letters = text.filter(\.isLetter)
        guard !letters.isEmpty else { return text }
        if letters.allSatisfy(\.isUppercase) { return text.lowercased() }
        if letters.allSatisfy(\.isLowercase) {
            guard let index = text.firstIndex(where: \.isLetter) else { return text }
            return text[..<index] + text[index].uppercased() + text[text.index(after: index)...]
        }
        return text.uppercased()
    }
}
