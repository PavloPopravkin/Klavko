import Foundation

/// Converts finished text between layouts, e.g. a selection "ghbdsn" -> "привіт".
public enum LayoutConverter {
    /// The layout whose letters make up most of the text; nil when there are no letters.
    public static func sourceLayout(of text: String, among layouts: [LayoutMap]) -> LayoutMap? {
        let scored = layouts.map { layout in
            (layout, text.filter { $0.isLetter && layout.keystroke(for: String($0)) != nil }.count)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    /// Retypes each character with the same key in `target`; characters with no key stay as is.
    public static func convert(_ text: String, from source: LayoutMap, to target: LayoutMap) -> String {
        text.map { character in
            guard let keystroke = source.keystroke(for: String(character)),
                  let converted = target.character(for: keystroke) else { return String(character) }
            return converted
        }.joined()
    }
}
