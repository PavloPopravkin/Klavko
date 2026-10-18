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
        "ru": [
            "а", "б", "в", "ж", "и", "к", "о", "с", "у", "я", "аж", "бы", "во", "вы", "да", "до", "же", "за",
            "из", "им", "их", "ли", "мы", "на", "не", "ни", "но", "ну", "ой", "он", "от", "по", "со", "та",
            "те", "то", "ту", "ты", "уж", "без", "был", "вам", "вас", "вот", "все", "всё", "где", "два",
            "для", "его", "её", "ещё", "как", "кто", "мне", "мой", "нам", "нас", "нет", "ним", "них", "она",
            "оно", "они", "при", "про", "раз", "сам", "так", "там", "тем", "тех", "тот", "три", "тут", "уже",
            "чем", "что", "эта", "это", "эти",
        ],
        "de": [
            "ab", "am", "an", "da", "du", "er", "es", "im", "in", "ja", "ob", "so", "um", "wo", "zu", "alt",
            "auf", "aus", "bei", "bin", "das", "dem", "den", "der", "des", "die", "ein", "gut", "hat", "ich",
            "ihr", "ist", "mal", "man", "mit", "neu", "nie", "nun", "nur", "oft", "uns", "von", "vor", "war",
            "was", "wer", "wie", "wir", "für",
        ],
        "fr": [
            "à", "a", "y", "au", "ce", "de", "du", "en", "et", "il", "je", "la", "le", "ma", "me", "ne", "ni",
            "on", "ou", "où", "sa", "se", "si", "ta", "te", "tu", "un", "va", "aux", "ces", "des", "est",
            "eux", "ils", "les", "lui", "mes", "moi", "mon", "non", "nos", "oui", "par", "pas", "peu", "que",
            "qui", "ses", "son", "sur", "toi", "ton", "une", "vos",
        ],
        "es": [
            "a", "e", "o", "u", "y", "al", "de", "el", "en", "es", "ha", "la", "le", "lo", "me", "mi", "ni",
            "no", "os", "se", "si", "su", "te", "tu", "tú", "un", "ya", "yo", "con", "del", "eso", "las",
            "los", "mas", "más", "muy", "nos", "por", "que", "qué", "sin", "son", "sus", "una", "uno", "ver",
            "vez",
        ],
        "it": [
            "a", "e", "i", "o", "ad", "al", "ci", "da", "di", "ed", "ha", "il", "in", "io", "la", "le", "lo",
            "ma", "mi", "ne", "no", "se", "si", "su", "ti", "tu", "un", "va", "che", "chi", "con", "del",
            "gli", "già", "non", "per", "più", "poi", "può", "qui", "sei", "sia", "suo", "tra", "una", "uno",
        ],
        "pt": [
            "a", "e", "o", "ao", "as", "da", "de", "do", "em", "eu", "há", "já", "lá", "me", "na", "no", "os",
            "se", "só", "te", "tu", "um", "é", "aos", "com", "das", "dos", "ela", "ele", "era", "mas", "mim",
            "nas", "nem", "nos", "não", "por", "que", "sem", "seu", "sim", "sua", "são", "tem", "uma", "vou",
        ],
        "pl": [
            "a", "i", "o", "u", "w", "z", "by", "do", "go", "ja", "je", "ją", "ma", "mi", "mu", "na", "od",
            "on", "po", "są", "ta", "to", "ty", "we", "za", "że", "ale", "bez", "był", "co", "dla", "ich",
            "jak", "jej", "już", "mam", "nam", "nas", "nic", "nie", "pan", "pod", "się", "tak", "tam", "ten",
            "też",
        ],
        "tr": [
            "o", "bu", "da", "de", "ki", "mi", "ne", "ve", "ya", "şu", "ama", "ben", "bir", "biz", "çok",
            "gün", "her", "hiç", "ile", "iyi", "kim", "sen", "siz", "var", "yok", "şey",
        ],
        "el": [
            "ο", "η", "ή", "αν", "δε", "θα", "κι", "με", "μη", "να", "οι", "σε", "τα", "τη", "τι", "το",
            "για", "δεν", "εγώ", "και", "μας", "ναι", "όχι", "που", "πώς", "σας", "στη", "στο", "την", "της",
            "τον", "του", "των", "από",
        ],
        "he": [
            "או", "אז", "אם", "גם", "זה", "זו", "כי", "כל", "כן", "לא", "לה", "לו", "לי", "לך", "מה", "מי",
            "עד", "על", "עם", "פה", "רק", "שם", "של", "יש", "אבל", "אין", "אני", "את", "הוא", "היא", "זאת",
        ],
        "ar": [
            "أو", "إن", "أن", "بل", "ثم", "عن", "في", "قد", "كل", "لا", "لم", "لن", "ما", "من", "مع", "هل",
            "هو", "هي", "أنا", "أنت", "إلى", "على", "كان", "نحن", "نعم", "هذا", "ذلك",
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
