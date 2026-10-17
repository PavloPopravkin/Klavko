import Foundation

/// Tidies speech recognition output. Parakeet has no token for some characters (dashes, «quotes»)
/// and writes `<unk>` in their place; this puts the character the spot calls for back.
public enum TranscriptCleanup {
    private static let unknownMarkers = ["<unk>", "⁇"]

    public static func clean(_ text: String) -> String {
        guard unknownMarkers.contains(where: text.contains) else { return text }
        let ukrainian = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let (open, close) = ukrainian ? ("«", "»") : ("“", "”")

        var marked = text
        for marker in unknownMarkers { marked = marked.replacingOccurrences(of: marker, with: "\u{0}") }
        let characters = Array(marked)
        var result = ""
        var quoteOpen = false
        for (index, character) in characters.enumerated() {
            guard character == "\u{0}" else {
                result.append(character)
                continue
            }
            let before = index > 0 ? characters[index - 1] : nil
            let after = index + 1 < characters.count ? characters[index + 1] : nil
            let spaceBefore = before.map(\.isWhitespace) ?? true
            let spaceAfter = after.map(\.isWhitespace) ?? true
            if spaceBefore && spaceAfter {
                // Alone between words: a dash ("Київ <unk> столиця"); dropped at the very start or end.
                if before != nil && after != nil { result.append("—") }
            } else if spaceBefore && !quoteOpen {
                result.append(open)       // <unk>слово → «слово
                quoteOpen = true
            } else if !spaceBefore && (spaceAfter || after.map(\.isPunctuation) ?? true) && quoteOpen {
                result.append(close)      // слово<unk> → слово»
                quoteOpen = false
            } else if let before, let after, before.isLetter, after.isLetter {
                result.append("-")        // inside a word: a hyphen
            } else if spaceBefore {
                result.append(open)
                quoteOpen = true
            } else {
                result.append(close)
                quoteOpen = false
            }
        }
        // Tidy spaces left around dropped markers.
        return result
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
