import Foundation

/// Which layout a word typed in the wrong one was meant for, when more than two are enabled
/// (English, Ukrainian, Russian, German…).
public enum LayoutChoice {
    /// The layouts to convert into from `current`, most likely first: one per language other than
    /// the current one; a different alphabet before the same one ("ghbdsn" is far more often Ukrainian
    /// typed in the English layout than German), then the more recently used (`recent`: layout IDs,
    /// latest first), then the order macOS lists them in.
    public static func alternatives(to current: LayoutMap, among layouts: [LayoutMap],
                                    recent: [String] = []) -> [LayoutMap] {
        func rank(_ layout: LayoutMap) -> Int { recent.firstIndex(of: layout.id) ?? recent.count }
        let others = layouts.enumerated()
            .filter { $0.element.language != current.language }
            .sorted { a, b in
                let aOther = a.element.script != current.script, bOther = b.element.script != current.script
                if aOther != bOther { return aOther }
                if rank(a.element) != rank(b.element) { return rank(a.element) < rank(b.element) }
                return a.offset < b.offset
            }
            .map(\.element)
        var seen: Set<String> = []
        return others.filter { seen.insert($0.language).inserted }
    }

    /// The alternative in which `text` reads most like real words (share of dictionary words),
    /// or the first one when none of them does better than the others.
    public static func best(for text: String, from source: LayoutMap, among alternatives: [LayoutMap],
                            spellChecker: SpellChecking) -> LayoutMap? {
        var best: (layout: LayoutMap, share: Double)?
        for layout in alternatives {
            let converted = LayoutConverter.convert(text, from: source, to: layout)
            let share = LanguageGuess.wordShare(converted, language: layout.language, spellChecker: spellChecker)
            if share > (best?.share ?? 0) { best = (layout, share) }
        }
        return best?.layout ?? alternatives.first
    }
}
