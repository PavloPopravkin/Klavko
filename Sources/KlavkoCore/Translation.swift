import Foundation

/// Which way to translate a selection: Ukrainian ↔ English, never anything else.
public enum TranslationDirection: Equatable, Sendable {
    case ukrainianToEnglish
    case englishToUkrainian

    /// Mostly Cyrillic letters → into English; otherwise → into Ukrainian.
    public init(for text: String) {
        var cyrillic = 0
        var latin = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            switch scalar.value {
            case 0x0400...0x04FF: cyrillic += 1
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: latin += 1
            default: break
            }
        }
        self = cyrillic > latin ? .ukrainianToEnglish : .englishToUkrainian
    }

    public var source: String { self == .ukrainianToEnglish ? "uk" : "en" }
    public var target: String { self == .ukrainianToEnglish ? "en" : "uk" }
    public var reversed: TranslationDirection { self == .ukrainianToEnglish ? .englishToUkrainian : .ukrainianToEnglish }
    public var title: String { self == .ukrainianToEnglish ? "🇺🇦 → 🇺🇸" : "🇺🇸 → 🇺🇦" }
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
