import Foundation

/// The "what's new" part of a GitHub release description, for the update prompt.
///
/// Release notes mark it with a bold heading — `**Що нового в 0.13.0:**` (and, for other interface
/// languages, optionally `**What’s new in 0.13.0:**`) — followed by a list of `- …` lines. Text right
/// after the heading counts as an item too. Markdown marks are removed.
public enum ReleaseNotes {
    public static func whatsNew(_ notes: String, english: Bool = false, limit: Int = 6) -> [String] {
        let lines = notes.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let ukrainian = ["що нового", "що виправлено", "нове"]
        let other = ["what's new", "what’s new", "what's fixed", "what’s fixed"]
        let wanted = english ? other + ukrainian : ukrainian + other
        // The heading of the preferred language if there is one, else any.
        for prefixes in [english ? other : ukrainian, wanted] {
            if let index = lines.firstIndex(where: { isHeading($0, prefixes) }) {
                return Array(items(after: index, in: lines).prefix(limit))
            }
        }
        // No heading: the first paragraph that isn't a heading of its own.
        if let first = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) { return [plain(first)] }
        return []
    }

    private static func isHeading(_ line: String, _ prefixes: [String]) -> Bool {
        guard line.hasPrefix("**") || line.hasPrefix("#") else { return false }
        let text = plain(line).lowercased()
        return prefixes.contains { text.hasPrefix($0) }
    }

    private static func items(after index: Int, in lines: [String]) -> [String] {
        var result: [String] = []
        // "**Що нового в 0.12.0:** автоматичні оновлення." — the text after the heading.
        let heading = lines[index]
        if let close = heading.range(of: "**", range: heading.index(heading.startIndex, offsetBy: 2)..<heading.endIndex) {
            let rest = plain(String(heading[close.upperBound...]))
            if !rest.isEmpty { result.append(rest) }
        }
        var started = !result.isEmpty
        for line in lines.dropFirst(index + 1) {
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                result.append(plain(String(line.dropFirst(2))))
                started = true
            } else if line.isEmpty {
                if started && result.count > 1 { break }
            } else if started {
                break
            }
        }
        return result.filter { !$0.isEmpty }
    }

    /// Without `**`, `` ` `` and link addresses: "[подякувати](https://…)" → "подякувати".
    static func plain(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        while let open = result.range(of: "]("), let close = result.range(of: ")", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
            result = result.replacingOccurrences(of: "[", with: "")
        }
        return result.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
    }
}
