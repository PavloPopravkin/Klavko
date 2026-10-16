import Foundation

/// Ukrainian word forms the system dictionary may lack.
public enum UkrainianForms {
    /// Vocative endings and how to get back to the dictionary form:
    /// Валентине → Валентин, Петре → Петро, Олеже → Олег, козаче → козак, Сергію → Сергій,
    /// Василю → Василь, Ігорю → Ігор, Миколо → Микола, Маріє → Марія, сину → син, батьку → батько.
    private static let vocativeRules: [(ending: String, replacements: [String])] = [
        ("же", ["г", "жа"]),
        ("че", ["к"]),
        ("ше", ["х"]),
        ("е", ["", "о", "а"]),
        ("ію", ["ій", "ія"]),
        ("ю", ["й", "ь", ""]),
        ("о", ["а"]),
        ("є", ["я"]),
        ("у", ["", "о"]),
    ]

    /// Possible dictionary forms of `word` if it is a vocative ("Валентине" → ["Валентин", "Валентино", …]).
    public static func vocativeBases(of word: String) -> [String] {
        var bases: [String] = []
        for rule in vocativeRules where word.hasSuffix(rule.ending) && word.count > rule.ending.count + 1 {
            let stem = String(word.dropLast(rule.ending.count))
            bases += rule.replacements.map { stem + $0 }
        }
        return bases
    }

    /// Plural case endings the system dictionary often lacks for nouns in -ння, -ття and others
    /// ("налаштуваннях", "налаштуваннями", "перемиканнях"), and the singular endings of their base form.
    private static let pluralEndings = ["ями", "ами", "ях", "ах", "ям", "ам", "ів", "їв"]
    private static let baseEndings = ["я", "а", "ь", "й", "", "і", "и", "о"]

    /// "налаштуваннях": a plural case form of a word the dictionary knows ("налаштування").
    /// Deliberately narrow (only plural endings), so a real typo such as "питаня" isn't excused.
    public static func isPluralFormOfKnownWord(_ word: String, spellChecker: SpellChecking) -> Bool {
        let lowered = word.lowercased()
        for ending in pluralEndings where lowered.hasSuffix(ending) {
            let stem = String(lowered.dropLast(ending.count))
            guard stem.count >= 3 else { continue }
            if baseEndings.contains(where: { spellChecker.isValid(stem + $0, language: "uk") }) { return true }
        }
        return false
    }

    /// A name in the vocative that the dictionary doesn't list, but whose usual form it does ("Валентине").
    /// Only capitalized words: common nouns' vocatives are in the dictionary, and a misspelled
    /// lowercase word shouldn't slip through as a "vocative".
    public static func isVocativeOfKnownName(_ word: String, spellChecker: SpellChecking) -> Bool {
        guard word.first?.isUppercase == true else { return false }
        return vocativeBases(of: word).contains { spellChecker.isValid($0, language: "uk") }
    }
}
