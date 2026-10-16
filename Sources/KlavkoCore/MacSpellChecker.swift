import AppKit

/// Spell checking via the built-in macOS dictionaries (includes words the user taught the system).
/// Everything runs locally; nothing is sent anywhere.
public final class MacSpellChecker: SpellChecking {
    private let checker = NSSpellChecker.shared
    /// Completions per "language:prefix"; prefixes repeat a lot while typing.
    private var completionCache: [String: [String]] = [:]

    public init() {}

    public func isValid(_ word: String, language: String) -> Bool {
        let range = checker.checkSpelling(of: word, startingAt: 0, language: language,
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    public func hasCompletions(_ prefix: String, language: String) -> Bool {
        !completions(for: prefix, language: language).isEmpty
    }

    public func completions(for prefix: String, language: String) -> [String] {
        let key = language + ":" + prefix
        if let cached = completionCache[key] { return cached }
        let range = NSRange(location: 0, length: (prefix as NSString).length)
        let result = checker.completions(forPartialWordRange: range, in: prefix, language: language,
                                         inSpellDocumentWithTag: 0) ?? []
        if completionCache.count > 2000 { completionCache.removeAll() }
        completionCache[key] = result
        return result
    }

    public func correction(for word: String, language: String, context: String) -> String? {
        let (text, range) = Self.place(word, after: context)
        return checker.correction(forWordRange: range, in: text, language: language, inSpellDocumentWithTag: 0)
    }

    public func guesses(for word: String, language: String, context: String) -> [String] {
        let (text, range) = Self.place(word, after: context)
        return checker.guesses(forWordRange: range, in: text, language: language, inSpellDocumentWithTag: 0) ?? []
    }

    /// One pass over all words instead of a call per word (hundreds of candidates in a few ms).
    public func validWords(among words: [String], language: String) -> Set<String> {
        guard !words.isEmpty else { return [] }
        // A fixed language: automatic detection would judge each candidate in whatever language it resembles.
        checker.automaticallyIdentifiesLanguages = false
        guard checker.setLanguage(language) else {
            return Set(words.filter { isValid($0, language: language) })
        }
        let text = words.joined(separator: " ")
        let nsText = text as NSString
        var orthography: NSOrthography?
        var wordCount = 0
        let results = checker.check(text, range: NSRange(location: 0, length: nsText.length),
                                    types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                                    options: [:], inSpellDocumentWithTag: 0,
                                    orthography: &orthography, wordCount: &wordCount)
        let misspelled = Set(results.map { nsText.substring(with: $0.range) })
        return Set(words.filter { !misspelled.contains($0) })
    }

    /// The word after its preceding text, so suggestions can take neighbouring words into account.
    private static func place(_ word: String, after context: String) -> (String, NSRange) {
        let prefix = context.isEmpty || context.hasSuffix(" ") ? context : context + " "
        let text = prefix + word
        return (text, NSRange(location: (prefix as NSString).length, length: (word as NSString).length))
    }
}
