import Foundation

/// Common words of one to three letters. Short wrong-layout words can't be judged by the dictionary:
/// "ye" (= "ну"), "wt" (= "це"), "db" (= "ви") are all valid English. So a short word is converted only
/// into a common short word of the other language, and only if what was typed isn't a common one itself.
public enum ShortWords {
    public static let maxLength = 3

    public static let common: [String: Set<String>] = [
        "uk": [
            "а", "б", "в", "ж", "з", "і", "й", "о", "у", "я",
            "аж", "би", "бо", "ви", "де", "до", "же", "за", "її", "із", "їй", "їм", "їх", "як", "ми", "на",
            "не", "ні", "ну", "ой", "ок", "от", "по", "та", "ти", "то", "ті", "це", "ці", "чи", "ще", "що",
            "ага", "або", "але", "без", "вам", "вас", "вже", "він", "від", "все", "вся", "всі", "для", "ось",
            "мій", "між", "моє", "мої", "над", "нам", "нас", "наш", "ним", "них", "ніж", "під", "при", "про",
            "сам", "так", "там", "теж", "тим", "тих", "тут", "хто", "чим", "чий", "ще", "якщо", "щоб",
        ],
        "en": [
            "a", "i",
            "am", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "if", "in", "is", "it", "me", "my",
            "no", "of", "oh", "ok", "on", "or", "so", "to", "up", "us", "we", "yo",
            "ago", "all", "and", "any", "are", "ask", "big", "but", "can", "day", "did", "few", "for", "get",
            "got", "had", "has", "her", "hey", "him", "his", "how", "its", "let", "lol", "man", "may", "new",
            "not", "now", "off", "old", "one", "our", "out", "own", "per", "put", "run", "say", "see", "set",
            "she", "the", "too", "top", "try", "two", "use", "via", "was", "way", "who", "why", "wow", "yes",
            "yet", "you",
        ],
    ]

    public static func isCommon(_ word: String, language: String) -> Bool {
        common[language]?.contains(word.lowercased()) ?? false
    }

    /// "z" typed for "я": a one-letter word that is a common word in the other layout, but too
    /// ambiguous to switch on its own. The next word decides.
    public static func isLoneLetterCandidate(typed: String, typedLanguage: String,
                                             alternative: String, alternativeLanguage: String) -> Bool {
        typed.count == 1 && alternative.count == 1
            && alternative.first?.isLetter == true
            && isCommon(alternative, language: alternativeLanguage)
            && !isCommon(typed, language: typedLanguage)
    }
}
