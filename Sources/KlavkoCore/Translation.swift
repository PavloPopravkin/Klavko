import Foundation

import NaturalLanguage

/// Which way to translate a selection: from the language it's written in to English, or from English
/// into the user's own language ("home").
public struct TranslationDirection: Equatable, Sendable {
    public let source: String
    public let target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }

    public static let ukrainianToEnglish = TranslationDirection(source: "uk", target: "en")
    public static let englishToUkrainian = TranslationDirection(source: "en", target: "uk")

    /// English (or no letters) → into `home`; any other language → into English.
    /// `languages`: the ones to tell apart (the keyboard layouts'); `home` and English always count.
    public init(for text: String, home: String = "uk", languages: [String] = []) {
        let home = home == "en" ? "uk" : home
        let source = Self.language(of: text, among: [home, "en"] + languages) ?? "en"
        self = source == "en" ? TranslationDirection(source: "en", target: home)
            : TranslationDirection(source: source, target: "en")
    }

    /// The language `text` is written in, of `candidates`; nil when it has no letters.
    static func language(of text: String, among candidates: [String]) -> String? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Array(Set(candidates)).map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        if let best = recognizer.dominantLanguage?.rawValue, candidates.contains(best) { return best }
        // The recognizer had nothing to go on: Cyrillic is the home language, anything else English.
        let cyrillic = letters.filter { (0x0400...0x04FF).contains($0.value) }.count
        return cyrillic * 2 > letters.count ? candidates.first : "en"
    }

    public var reversed: TranslationDirection { TranslationDirection(source: target, target: source) }
    public var title: String { LanguageFlags.label(source) + " → " + LanguageFlags.label(target) }
}

/// The flag shown for a language (menu bar, translation panel); one place for all of them.
public enum LanguageFlags {
    /// Arabic has no single country: it shows "AR". Russian shows a grey flag in the menu bar,
    /// a plain "RU" in text.
    public static let emoji = ["uk": "🇺🇦", "en": "🇺🇸", "de": "🇩🇪", "fr": "🇫🇷", "es": "🇪🇸", "it": "🇮🇹",
                               "pt": "🇵🇹", "pl": "🇵🇱", "tr": "🇹🇷", "el": "🇬🇷", "he": "🇮🇱"]

    /// The flag, or the language code in capitals.
    public static func label(_ language: String) -> String { emoji[language] ?? language.uppercased() }
}

/// Text split into lines so a translation keeps the selection's line breaks, blank lines,
/// indentation and trailing spaces exactly; only the words in each line get translated.
public struct TranslationLines: Sendable {
    private struct Line: Sendable {
        let leading: String
        let core: String
        let trailing: String
    }

    private let lines: [Line]

    public init(_ text: String) {
        lines = text.components(separatedBy: "\n").map { line in
            let leading = line.prefix { $0.isWhitespace }
            let rest = line.dropFirst(leading.count)
            let trailing = String(rest.reversed().prefix { $0.isWhitespace }.reversed())
            return Line(leading: String(leading), core: String(rest.dropLast(trailing.count)), trailing: trailing)
        }
    }

    /// The non-empty lines, in order: what to hand to the translator.
    public var toTranslate: [String] { lines.map(\.core).filter { !$0.isEmpty } }

    /// The original layout with `translated` (one per `toTranslate` entry) put back in place.
    public func assemble(_ translated: [String]) -> String {
        var next = translated.makeIterator()
        return lines.map { line in
            guard !line.core.isEmpty else { return line.leading + line.trailing }
            return line.leading + (next.next() ?? line.core) + line.trailing
        }.joined(separator: "\n")
    }
}
