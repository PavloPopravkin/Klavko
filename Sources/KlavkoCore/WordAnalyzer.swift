import Foundation

public protocol SpellChecking {
    func isValid(_ word: String, language: String) -> Bool
    /// True when some dictionary word starts with `prefix`.
    func hasCompletions(_ prefix: String, language: String) -> Bool
    /// Dictionary words starting with `prefix`, most common first.
    func completions(for prefix: String, language: String) -> [String]
    /// The system's best fix for a misspelled word, given the text before it.
    func correction(for word: String, language: String, context: String) -> String?
    /// Suggested spellings for a misspelled word, most likely first, given the text before it.
    func guesses(for word: String, language: String, context: String) -> [String]
    /// Which of `words` are in the dictionary (checked in one batch).
    func validWords(among words: [String], language: String) -> Set<String>
}

/// Decides whether a word was typed in the wrong layout.
public struct WordAnalyzer {
    public var minimumLength = 2
    /// Mid-word switching needs this many letters; shorter prefixes are too ambiguous.
    public var minimumPrefixLength = 3
    /// Whether words typed entirely in capitals (likely abbreviations: NATO, ЗСУ) may be converted.
    public var convertAbbreviations = false
    /// The user's exceptions: words (as typed, lowercased) Klavko never converts.
    public var exceptions: Set<String> = []

    private let spellChecker: SpellChecking

    public init(spellChecker: SpellChecking) {
        self.spellChecker = spellChecker
    }

    /// For a finished word. `typed` is what appeared on screen in `typedLanguage`;
    /// `alternative` is the same keystrokes rendered in `alternativeLanguage`.
    /// `contextLanguage`: the language of the word before it, if known.
    public func shouldConvert(typed: String, typedLanguage: String,
                              alternative: String, alternativeLanguage: String,
                              contextLanguage: String? = nil) -> Bool {
        if typed.contains(where: \.isNumber) { return false }

        let typedWord = TextRules.coreWord(typed)
        let alternativeWord = TextRules.coreWord(alternative)
        if exceptions.contains(typedWord.lowercased()) { return false }
        if !convertAbbreviations && TextRules.isAllCaps(typedWord) { return false }

        if !alternativeWord.isEmpty, alternativeWord.count <= ShortWords.maxLength {
            return shouldConvertShort(typedWord, typedLanguage: typedLanguage,
                                      alternativeWord, alternativeLanguage: alternativeLanguage,
                                      contextLanguage: contextLanguage)
        }
        guard alternativeWord.count >= minimumLength else { return false }

        if !typedWord.isEmpty && spellChecker.isValid(Self.spellingForm(typedWord), language: typedLanguage) {
            return false
        }
        return spellChecker.isValid(Self.spellingForm(alternativeWord), language: alternativeLanguage)
    }

    /// macOS accepts any all-caps word as an acronym, so check those in lowercase.
    private static func spellingForm(_ word: String) -> String {
        TextRules.isAllCaps(word) ? word.lowercased() : word
    }

    /// One to three letters ("ye" -> "ну"): see `ShortWords`.
    /// A single letter ("z" -> "я") also needs the previous word to be in the other language.
    private func shouldConvertShort(_ typedWord: String, typedLanguage: String,
                                    _ alternativeWord: String, alternativeLanguage: String,
                                    contextLanguage: String?) -> Bool {
        guard ShortWords.isCommon(alternativeWord, language: alternativeLanguage) else { return false }
        // In the middle of a sentence in the other language, trust the context.
        if contextLanguage == alternativeLanguage { return true }
        // A single letter is too ambiguous without it.
        if alternativeWord.count < minimumLength { return false }
        if ShortWords.isCommon(typedWord, language: typedLanguage) { return false }
        // Rare two-letter "words" (ye, wt, db) don't count, but a real three-letter one ("рук") does.
        if typedWord.count >= 3 && spellChecker.isValid(typedWord, language: typedLanguage) { return false }
        return true
    }

    /// For a word still being typed: switch when no word starts like the typed text
    /// but many words start like the alternative ("ghb" vs "при").
    public func shouldConvertPrefix(typed: String, typedLanguage: String,
                                    alternative: String, alternativeLanguage: String) -> Bool {
        if typed.contains(where: \.isNumber) { return false }

        let typedWord = TextRules.coreWord(typed)
        let typedLower = typedWord.lowercased()
        let alternativeWord = alternative.lowercased()
        guard alternativeWord.count >= minimumPrefixLength,
              TextRules.coreWord(alternativeWord) == alternativeWord else { return false }
        // The prefix may still grow into an exception word: wait for the end of the word.
        // Also an exception saved from a word reverted halfway ("ghb") covers every word it begins.
        if exceptions.contains(where: {
            $0.hasPrefix(typedLower) || ($0.count >= minimumPrefixLength && typedLower.hasPrefix($0))
        }) { return false }
        if !convertAbbreviations && TextRules.isAllCaps(typedWord) { return false }

        if !typedLower.isEmpty && (spellChecker.hasCompletions(typedLower, language: typedLanguage)
                                   || spellChecker.isValid(typedLower, language: typedLanguage)) {
            return false
        }
        return spellChecker.hasCompletions(alternativeWord, language: alternativeLanguage)
    }
}
