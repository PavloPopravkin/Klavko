import Foundation

/// Fixes obvious spelling mistakes locally, using the macOS dictionaries:
/// a stuck Shift ("ПРивіт" -> "Привіт") and slips such as a missing letter ("дкую" -> "дякую"),
/// an extra or swapped letter, or a neighbouring key ("рлбиш" -> "робиш").
///
/// How a word is fixed:
/// 1. Candidates: every dictionary word one edit away (insert/delete/swap/replace a letter, checked
///    in one batch), plus the system's own suggestions for the word in its sentence.
/// 2. Ranking: score = typing cost − how common the word is − support from the sentence context.
///    A missing letter is the cheapest slip, a far-away key the most expensive.
/// 3. Confidence: the winner must be close, backed by frequency or context, and clearly ahead of
///    the runner-up. Otherwise the word stays as typed.
public struct TypoCorrector {
    public var minimumLength = 4
    /// The winner must beat the runner-up's score by this much…
    public var minimumMargin = 0.3
    /// …and by more for words of four letters or fewer, where many dictionary words are one slip apart.
    public var shortWordMargin = 0.5
    /// The user's exceptions: words (as typed, lowercased) never to touch.
    public var exceptions: Set<String> = []

    private let spellChecker: SpellChecking

    public init(spellChecker: SpellChecking) {
        self.spellChecker = spellChecker
    }

    /// The corrected word, keeping surrounding quotes/brackets and the first letter's case; nil to leave it.
    /// - layout: gives key positions, so neighbouring-key slips rank higher.
    /// - allowCapitalized: false mid-sentence, where a capitalized unknown word is likely a name.
    /// - context: the text typed before the word in the same sentence.
    public func correction(for word: String, language: String, layout: LayoutMap?,
                           allowCapitalized: Bool, context: String = "") -> String? {
        let leading = String(word.prefix { !$0.isLetter })
        let trailing = String(word.reversed().prefix { !$0.isLetter }.reversed())
        let core = TextRules.coreWord(word)

        guard leading.count + trailing.count < word.count, !core.isEmpty,
              !word.contains(where: \.isNumber),
              !TextRules.isAllCaps(core),
              !TextRules.mixesScripts(core),
              !exceptions.contains(core.lowercased())
        else { return nil }

        // Stuck Shift: always fix the case, then the spelling if still needed.
        // (macOS ignores letter case when checking, so "ПРивіт" alone would pass as correct.)
        if let caseFixed = Self.stuckShiftFix(core) {
            if spellChecker.isValid(caseFixed, language: language) || isKnownForm(caseFixed, language: language) {
                return leading + caseFixed + trailing
            }
            let fixed = bestCandidate(for: caseFixed, language: language, layout: layout, context: context)
            return leading + (fixed ?? caseFixed) + trailing
        }

        guard core.count >= minimumLength, let first = core.first, allowCapitalized || !first.isUppercase,
              !spellChecker.isValid(core, language: language),
              !isKnownForm(core, language: language),
              let fixed = bestCandidate(for: core, language: language, layout: layout, context: context)
        else { return nil }
        return leading + fixed + trailing
    }

    /// A correct form the dictionary lacks: a name in the vocative ("Валентине")
    /// or a plural case form ("налаштуваннях").
    private func isKnownForm(_ word: String, language: String) -> Bool {
        language == "uk" && (UkrainianForms.isVocativeOfKnownName(word, spellChecker: spellChecker)
                             || UkrainianForms.isPluralFormOfKnownWord(word, spellChecker: spellChecker))
    }

    /// "ПРивіт" -> "Привіт": exactly two capitals, then at least two lowercase letters.
    public static func stuckShiftFix(_ word: String) -> String? {
        let letters = Array(word)
        guard letters.count >= 4, letters[0].isUppercase, letters[1].isUppercase,
              letters[2...].filter(\.isLetter).count >= 2,
              letters[2...].allSatisfy({ !$0.isLetter || $0.isLowercase })
        else { return nil }
        return String(letters[0]) + String(letters[1...]).lowercased()
    }

    // MARK: - Ranking

    public struct Candidate: Equatable {
        public let word: String
        /// Typing cost of the slip (see `slipDistance`).
        public let cost: Double
        /// 0…0.6: how common the word is.
        public let frequency: Double
        /// 0…0.55: how strongly the system's in-context suggestions back it.
        public let support: Double

        public var score: Double { cost - frequency - support }
    }

    /// All candidates for a misspelled word, best first. Exposed for tests and diagnostics.
    public func rankedCandidates(for word: String, language: String, layout: LayoutMap?,
                                 context: String = "") -> [Candidate] {
        let lowered = word.lowercased()
        // The system's guesses add words two edits away, which only long words may be (≈6 ms, so skipped otherwise).
        let suggestions = lowered.count >= 8
            ? spellChecker.guesses(for: lowered, language: language, context: context).map { $0.lowercased() }
            : []
        let systemFix = spellChecker.correction(for: lowered, language: language, context: context)?.lowercased()

        // A far-away key is too unlikely for a short word; only long words may have one.
        let edits = Self.singleEdits(of: lowered, alphabet: Self.alphabet(for: language, word: lowered)) { typed, replacement in
            lowered.count >= 8 || KeyboardGeometry.areNeighbours(typed, replacement, layout: layout)
        }
        var words = spellChecker.validWords(among: Array(edits), language: language)
        words.formUnion(suggestions)
        if let systemFix { words.insert(systemFix) }
        words = words.filter { !$0.isEmpty && !$0.contains(" ") && $0 != lowered }

        // Frequency costs a dictionary lookup per candidate, so it's computed only where it can change
        // the top two: a candidate whose best possible score can't beat the runner-up keeps frequency 0.
        let maxFrequency = 0.6
        let cheap = words.map { candidate -> Candidate in
            var support = 0.0
            if candidate == systemFix { support += 0.4 }
            if let rank = suggestions.firstIndex(of: candidate), rank < 3 {
                support += 0.15 * Double(3 - rank) / 3
            }
            return Candidate(word: candidate,
                             cost: Self.slipDistance(typed: lowered, intended: candidate, layout: layout),
                             frequency: 0, support: support)
        }.sorted { $0.score < $1.score }

        var ranked: [Candidate] = []
        for candidate in cheap {
            let runnerUp = ranked.count >= 2 ? ranked.map(\.score).sorted()[1] : .infinity
            if candidate.score - maxFrequency >= runnerUp {
                ranked.append(candidate)
                continue
            }
            ranked.append(Candidate(word: candidate.word, cost: candidate.cost,
                                    frequency: frequency(of: candidate.word, language: language),
                                    support: candidate.support))
        }
        return ranked.sorted { a, b in
            a.score != b.score ? a.score < b.score : a.word < b.word
        }
    }

    private func bestCandidate(for word: String, language: String, layout: LayoutMap?, context: String) -> String? {
        let ranked = rankedCandidates(for: word, language: language, layout: layout, context: context)
        guard let best = ranked.first,
              // One slip for ordinary words; long words may have two.
              best.cost <= (word.count >= 8 ? 1.6 : 1.0),
              // A real, common word or one the sentence context points to — not just any string that's close.
              best.frequency > 0 || best.support >= 0.4
        else { return nil }
        let margin = word.count <= 4 ? shortWordMargin : minimumMargin
        if ranked.count > 1, ranked[1].score - best.score < margin { return nil }

        let fix = best.word
        return word.first?.isUppercase == true ? fix.prefix(1).uppercased() + fix.dropFirst() : fix
    }

    /// How common a word is, judged by its place in the system's completions (most common first)
    /// for its first two and three letters.
    private func frequency(of word: String, language: String) -> Double {
        var best = 0.0
        for (length, weight) in [(2, 0.6), (3, 0.4)] where word.count >= length {
            let list = spellChecker.completions(for: String(word.prefix(length)), language: language)
            if let rank = list.firstIndex(of: word) {
                best = max(best, weight * (1 - Double(rank) / Double(max(list.count, 20))))
            }
        }
        return best
    }

    // MARK: - Candidates

    private static let ukrainianAlphabet = Array("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя'")
    private static let englishAlphabet = Array("abcdefghijklmnopqrstuvwxyz'")

    private static func alphabet(for language: String, word: String) -> [Character] {
        switch language {
        case "uk": ukrainianAlphabet
        case "en": englishAlphabet
        default: Array(Set(word))
        }
    }

    /// Every string one edit away: a letter inserted, deleted, replaced, or two neighbours swapped.
    /// `allowReplacement(typed, replacement)` limits which replacements are tried.
    /// (An apostrophe is never placed at either end.)
    public static func singleEdits(of word: String, alphabet: [Character],
                                   allowReplacement: (Character, Character) -> Bool = { _, _ in true }) -> Set<String> {
        let letters = Array(word)
        var result: Set<String> = []
        for index in 0...letters.count {
            for character in alphabet {
                if character == "'" && (index == 0 || index == letters.count) { continue }
                var edited = letters
                edited.insert(character, at: index)
                result.insert(String(edited))
            }
        }
        for index in letters.indices {
            if letters.count > 1 {
                var edited = letters
                edited.remove(at: index)
                result.insert(String(edited))
            }
            for character in alphabet where character != letters[index] && character != "'"
                && allowReplacement(letters[index], character) {
                var edited = letters
                edited[index] = character
                result.insert(String(edited))
            }
            if index + 1 < letters.count {
                var edited = letters
                edited.swapAt(index, index + 1)
                result.insert(String(edited))
            }
        }
        result.remove(word)
        return result
    }

    // MARK: - Typing-aware distance

    private enum Cost {
        /// The most common slip when typing fast.
        static let missingLetter = 0.7
        static let missingDoubledLetter = 0.5
        static let extraLetter = 0.8
        static let extraDoubledLetter = 0.5
        static let neighbourKey = 0.8
        static let swap = 0.7
        static let otherKey = 1.4
    }

    /// How likely `typed` is a slip of `intended`: a missing letter costs least, a neighbouring key
    /// or swapped letters a bit more, an arbitrary wrong key the most.
    public static func slipDistance(typed: String, intended: String, layout: LayoutMap?) -> Double {
        let a = Array(typed), b = Array(intended)
        var d = [[Double]](repeating: [Double](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count where i > 0 { d[i][0] = d[i - 1][0] + Cost.extraLetter }
        for j in 0...b.count where j > 0 { d[0][j] = d[0][j - 1] + Cost.missingLetter }
        guard !a.isEmpty, !b.isEmpty else { return d[a.count][b.count] }

        for i in 1...a.count {
            for j in 1...b.count {
                let extra = i > 1 && a[i - 1] == a[i - 2] ? Cost.extraDoubledLetter : Cost.extraLetter
                let missing = j > 1 && b[j - 1] == b[j - 2] ? Cost.missingDoubledLetter : Cost.missingLetter
                let substitution = a[i - 1] == b[j - 1] ? 0
                    : KeyboardGeometry.areNeighbours(a[i - 1], b[j - 1], layout: layout) ? Cost.neighbourKey : Cost.otherKey
                var best = min(d[i - 1][j] + extra, d[i][j - 1] + missing, d[i - 1][j - 1] + substitution)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    best = min(best, d[i - 2][j - 2] + Cost.swap)
                }
                d[i][j] = best
            }
        }
        return d[a.count][b.count]
    }
}

/// Physical key positions of a Mac keyboard, to tell which keys are next to each other.
public enum KeyboardGeometry {
    /// Key codes row by row, left to right, and where each row starts (in key widths).
    private static let rows: [(start: Double, keys: [UInt16])] = [
        (0.0, [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]), // ` 1 … =
        (1.5, [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42]), // q … ] \
        (1.75, [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]),              // a … '
        (2.25, [6, 7, 8, 9, 11, 45, 46, 43, 47, 44]),                // z … /
    ]

    private static let positions: [UInt16: (row: Int, x: Double)] = {
        var result: [UInt16: (row: Int, x: Double)] = [:]
        for (row, line) in rows.enumerated() {
            for (column, key) in line.keys.enumerated() {
                result[key] = (row, line.start + Double(column))
            }
        }
        return result
    }()

    public static func areNeighbours(_ a: Character, _ b: Character, layout: LayoutMap?) -> Bool {
        guard let layout,
              let keyA = layout.keystroke(for: String(a).lowercased())?.keyCode,
              let keyB = layout.keystroke(for: String(b).lowercased())?.keyCode,
              keyA != keyB,
              let pa = positions[keyA], let pb = positions[keyB]
        else { return false }
        return abs(pa.row - pb.row) <= 1 && abs(pa.x - pb.x) <= 1.0
    }
}
