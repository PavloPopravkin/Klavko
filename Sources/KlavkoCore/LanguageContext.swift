import Foundation

/// What the text typed before a word says about its language: for each language, how many of the last
/// words on the line (this sentence and the ones before it) that language's dictionary knows.
/// A word of several languages ("дома" is Russian and Ukrainian) counts for each, so it never tips
/// the balance between them.
public struct LanguageContext: Equatable, Sendable {
    public private(set) var counts: [String: Int] = [:]
    /// Words the dictionaries know, in any language.
    public private(set) var words = 0

    public init() {}

    /// Text of one word in `language` (nil: nothing known yet).
    public init(_ language: String?) {
        if let language { add([language]) }
    }

    public mutating func add(_ languages: Set<String>) {
        guard !languages.isEmpty else { return }
        words += 1
        for language in languages { counts[language, default: 0] += 1 }
    }

    public var isEmpty: Bool { words == 0 }

    public func count(_ language: String) -> Int { counts[language] ?? 0 }

    /// More of the text is in `language` than in `other`.
    public func favors(_ language: String, over other: String) -> Bool {
        count(language) > count(other)
    }

    /// Builds it from `text`, the text before the word being typed: its last `limit` words, back to the
    /// start of the line at most (a new paragraph or message may be in another language). `languages` says which languages a word is in (empty: unknown).
    public static func of(_ text: some BidirectionalCollection<Character>, limit: Int = 6,
                          languages: (String) -> Set<String>) -> LanguageContext {
        var context = LanguageContext()
        for word in lastWords(of: text, limit: limit) { context.add(languages(word)) }
        return context
    }

    /// The words of the last line of `text`, lowercased, at most `limit` from its end.
    /// An apostrophe inside a word is part of it ("м'ята").
    static func lastWords(of text: some BidirectionalCollection<Character>, limit: Int) -> [String] {
        var words: [String] = []
        var current: [Character] = []
        func finish() {
            while current.last.map(Self.isApostrophe) == true { current.removeLast() }
            while current.first.map(Self.isApostrophe) == true { current.removeFirst() }
            if !current.isEmpty { words.append(String(current.reversed()).lowercased()) }
            current = []
        }
        for character in text.reversed() {
            if character.isLetter || (Self.isApostrophe(character) && !current.isEmpty) {
                current.append(character)
                continue
            }
            finish()
            if words.count >= limit || character.isNewline { break }
        }
        if words.count < limit { finish() }
        return Array(words.prefix(limit))
    }

    private static func isApostrophe(_ character: Character) -> Bool { "'’ʼ".contains(character) }

    /// The languages among `layouts` a word is in: of the layouts that type all its letters, those whose
    /// dictionary knows it (or whose common short words include it).
    public static func languages(of word: String, among layouts: [LayoutMap],
                                 spellChecker: SpellChecking) -> Set<String> {
        var result: Set<String> = []
        for layout in layouts where !result.contains(layout.language) {
            guard word.allSatisfy({ layout.keystroke(for: String($0)) != nil }) else { continue }
            let known = word.count <= ShortWords.maxLength
                ? ShortWords.isCommon(word, language: layout.language) || spellChecker.isValid(word, language: layout.language)
                : spellChecker.isValid(word, language: layout.language)
            if known { result.insert(layout.language) }
        }
        return result
    }
}
