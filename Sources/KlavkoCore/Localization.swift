import Foundation

/// The language of Klavko's own windows and menus: Ukrainian or English, chosen in Settings
/// (independent of the macOS language).
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case ukrainian = "uk"
    case english = "en"

    /// Set from Settings at launch and whenever it changes.
    nonisolated(unsafe) public static var current: AppLanguage = .systemDefault

    /// Ukrainian when macOS prefers it, English otherwise.
    public static var systemDefault: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("uk") == true ? .ukrainian : .english
    }

    /// Its own name, as shown in the picker.
    public var title: String {
        switch self {
        case .ukrainian: "Українська"
        case .english: "English"
        }
    }

    /// For dates and numbers.
    public var locale: Locale { Locale(identifier: self == .ukrainian ? "uk_UA" : "en_US") }
}

/// The text in the current interface language: `tr("Налаштування", "Settings")`.
public func tr(_ ukrainian: String, _ english: String) -> String {
    AppLanguage.current == .ukrainian ? ukrainian : english
}
