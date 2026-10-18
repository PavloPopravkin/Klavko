import Foundation

/// Version numbers like "0.11.1" (a leading "v" from a release tag is fine).
public enum AppVersion {
    public static func components(_ version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        let plain = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        return plain.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// "0.12.0" is newer than "0.11.1"; "0.11.10" is newer than "0.11.9"; "1.0" equals "1.0.0".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate)
        let b = components(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
