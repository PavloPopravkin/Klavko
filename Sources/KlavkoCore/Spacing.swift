import Foundation

/// Adds the space a user forgot after punctuation: "Привіт,як" -> "Привіт, як".
public enum Spacing {
    /// Marks that are always followed by a space before a word.
    static let marks: Set<Character> = [",", ";", ":", "!", "?", "…", "—", "–"]
    /// Characters that make the text before the mark look like an address or code, not prose.
    static let addressCharacters: Set<Character> = Set("@/\\_#=<>{}[]`~|$%&*+")

    /// Whether a space belongs between `before` (the text up to and including the last mark)
    /// and the letter `next` about to be typed.
    public static func needsSpace(before: String, next: Character) -> Bool {
        guard next.isLetter, let mark = before.last else { return false }

        // The run of marks at the end ("?!", "...") and the word before it.
        let marksRun = before.reversed().prefix { marks.contains($0) || $0 == "." }
        let rest = before.dropLast(marksRun.count)
        guard let beforeMarks = rest.last else { return false }
        let isDash = mark == "—" || mark == "–"
        // After a word, number or closing quote — or a dash set off by a space ("так —ні").
        // Not ":D" after a space or "(," with nothing before.
        guard beforeMarks.isLetter || beforeMarks.isNumber || "»\")'”’".contains(beforeMarks)
                || (isDash && beforeMarks == " ") else { return false }
        let token = rest.reversed().prefix { !$0.isWhitespace }
        if token.contains(where: addressCharacters.contains) { return false }

        if mark == "." {
            // After a full stop only before a capital ("Так.Ні"); "google.com", "т.д.", "file.txt" stay.
            // Not after initials or abbreviations like "U.S." or "т.д.".
            guard next.isUppercase, token.filter(\.isLetter).count > 1, !token.contains(".") else { return false }
            return true
        }
        guard marks.contains(mark) else { return false }
        // "http:" or "mailto:" — part of an address.
        if mark == ":" && ["http", "https", "mailto", "ftp", "file"].contains(String(token.reversed()).lowercased()) {
            return false
        }
        return true
    }
}
