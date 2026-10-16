import Foundation
import KlavkoCore
import ServiceManagement

/// User preferences, persisted in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    private enum Key {
        static let enabled = "enabled"
        static let switchWhileTyping = "switchWhileTyping"
        static let triggers = "triggers"
        static let backspaceUndo = "backspaceUndo"
        static let showFlag = "showFlag"
        static let playSound = "playSound"
        static let soundName = "soundName"
        static let excludedApps = "excludedApps"
        static let shortcuts = "shortcuts.v2"
        static let loginItemConfigured = "loginItemConfigured"
        static let loginItemPath = "loginItemPath"
        static let convertAbbreviations = "convertAbbreviations"
        static let exceptions = "exceptions"
        static let correctSpelling = "correctTypos"
        static let spaceAfterPunctuation = "spaceAfterPunctuation"
        static let autoCapitalize = "autoCapitalize"
        static let typography = "typography"
        static let listContinuation = "listContinuation"
        static let replacements = "replacements"
        static let aiModel = "aiModel"
        static let aiActions = "aiActions"
        static let voiceLanguage = "voiceLanguage"
        static let playSpellingSound = "playSpellingSound"
        static let spellingSoundName = "spellingSoundName"
        static let revertCounts = "revertCounts"
        static let declinedExceptions = "declinedExceptions"
    }

    /// Short, soft macOS system sounds that suit a quick fix.
    static let sounds = ["Pop", "Tink", "Purr", "Bottle", "Morse", "Frog", "Glass"]

    private let defaults = UserDefaults.standard

    /// Called after any change so the engine and the menu bar icon pick it up.
    var onChange: (() -> Void)?

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled); onChange?() }
    }

    @Published var switchWhileTyping: Bool {
        didSet { defaults.set(switchWhileTyping, forKey: Key.switchWhileTyping); onChange?() }
    }

    @Published private(set) var triggers: Set<SwitchTrigger> {
        didSet { defaults.set(triggers.map(\.rawValue).sorted(), forKey: Key.triggers); onChange?() }
    }

    @Published var backspaceUndo: Bool {
        didSet { defaults.set(backspaceUndo, forKey: Key.backspaceUndo); onChange?() }
    }

    @Published var convertAbbreviations: Bool {
        didSet { defaults.set(convertAbbreviations, forKey: Key.convertAbbreviations); onChange?() }
    }

    @Published var correctSpelling: Bool {
        didSet { defaults.set(correctSpelling, forKey: Key.correctSpelling); onChange?() }
    }

    @Published var spaceAfterPunctuation: Bool {
        didSet { defaults.set(spaceAfterPunctuation, forKey: Key.spaceAfterPunctuation); onChange?() }
    }

    @Published var autoCapitalize: Bool {
        didSet { defaults.set(autoCapitalize, forKey: Key.autoCapitalize); onChange?() }
    }

    @Published var typography: Bool {
        didSet { defaults.set(typography, forKey: Key.typography); onChange?() }
    }

    @Published var listContinuation: Bool {
        didSet { defaults.set(listContinuation, forKey: Key.listContinuation); onChange?() }
    }

    @Published var aiModel: AIModel {
        didSet { defaults.set(aiModel.rawValue, forKey: Key.aiModel); onChange?() }
    }

    /// The languages the user speaks: "auto" (Ukrainian and English), "uk" or "en". Never Russian.
    @Published var voiceLanguage: String {
        didSet { defaults.set(voiceLanguage, forKey: Key.voiceLanguage) }
    }

    /// AI actions offered for selected text, in menu order.
    @Published var aiActions: [AIAction] {
        didSet { defaults.set(try? JSONEncoder().encode(aiActions), forKey: Key.aiActions) }
    }

    /// The user's own replacements, in the order added.
    @Published private(set) var replacements: [Replacement] {
        didSet {
            defaults.set(try? JSONEncoder().encode(replacements), forKey: Key.replacements)
            onChange?()
        }
    }

    /// Words Klavko never converts, lowercased, sorted.
    @Published private(set) var exceptions: [String] {
        didSet { defaults.set(exceptions, forKey: Key.exceptions); onChange?() }
    }

    @Published var showFlag: Bool {
        didSet { defaults.set(showFlag, forKey: Key.showFlag); onChange?() }
    }

    @Published var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Key.playSound); onChange?() }
    }

    @Published var soundName: String {
        didSet { defaults.set(soundName, forKey: Key.soundName); onChange?() }
    }

    @Published var playSpellingSound: Bool {
        didSet { defaults.set(playSpellingSound, forKey: Key.playSpellingSound); onChange?() }
    }

    @Published var spellingSoundName: String {
        didSet { defaults.set(spellingSoundName, forKey: Key.spellingSoundName); onChange?() }
    }

    @Published private(set) var excludedApps: [String] {
        didSet { defaults.set(excludedApps, forKey: Key.excludedApps); onChange?() }
    }

    @Published private(set) var shortcuts: [HotkeyAction: Shortcut] {
        didSet { saveShortcuts(); onChange?() }
    }

    /// Lives in macOS (System Settings → General → Login Items), not in UserDefaults.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.engine.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    init() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.switchWhileTyping: true,
            Key.triggers: SwitchTrigger.allCases.map(\.rawValue),
            Key.backspaceUndo: true,
            Key.convertAbbreviations: false,
            Key.correctSpelling: true,
            Key.spaceAfterPunctuation: true,
            Key.autoCapitalize: true,
            Key.typography: true,
            Key.listContinuation: true,
            Key.showFlag: true,
            Key.playSound: true,
            Key.soundName: "Pop",
            Key.playSpellingSound: true,
            Key.spellingSoundName: "Tink",
            // Terminals: words there are mostly commands, not natural language.
            // Code editors: "...", quotes and capitals mean something else in code.
            Key.excludedApps: ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode",
                               "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
                               "com.sublimetext.4"],
        ])
        isEnabled = defaults.bool(forKey: Key.enabled)
        switchWhileTyping = defaults.bool(forKey: Key.switchWhileTyping)
        triggers = Set((defaults.stringArray(forKey: Key.triggers) ?? []).compactMap(SwitchTrigger.init(rawValue:)))
        backspaceUndo = defaults.bool(forKey: Key.backspaceUndo)
        convertAbbreviations = defaults.bool(forKey: Key.convertAbbreviations)
        exceptions = defaults.stringArray(forKey: Key.exceptions) ?? []
        correctSpelling = defaults.bool(forKey: Key.correctSpelling)
        spaceAfterPunctuation = defaults.bool(forKey: Key.spaceAfterPunctuation)
        autoCapitalize = defaults.bool(forKey: Key.autoCapitalize)
        typography = defaults.bool(forKey: Key.typography)
        listContinuation = defaults.bool(forKey: Key.listContinuation)
        let storedVoice = defaults.string(forKey: Key.voiceLanguage) ?? "auto"
        voiceLanguage = ["auto", "uk", "en"].contains(storedVoice) ? storedVoice : "auto"
        aiModel = defaults.string(forKey: Key.aiModel).flatMap(AIModel.init(rawValue:)) ?? .opus
        aiActions = defaults.data(forKey: Key.aiActions)
            .flatMap { try? JSONDecoder().decode([AIAction].self, from: $0) } ?? AIAction.defaults
        replacements = defaults.data(forKey: Key.replacements)
            .flatMap { try? JSONDecoder().decode([Replacement].self, from: $0) } ?? []
        showFlag = defaults.bool(forKey: Key.showFlag)
        playSound = defaults.bool(forKey: Key.playSound)
        soundName = defaults.string(forKey: Key.soundName) ?? "Pop"
        playSpellingSound = defaults.bool(forKey: Key.playSpellingSound)
        spellingSoundName = defaults.string(forKey: Key.spellingSoundName) ?? "Tink"
        excludedApps = defaults.stringArray(forKey: Key.excludedApps) ?? []
        shortcuts = Self.loadShortcuts(defaults.data(forKey: Key.shortcuts))
        launchAtLogin = SMAppService.mainApp.status == .enabled

        // Autostart is on by default, but only from an installed copy: a build folder may move or vanish.
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
            || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
        if installed && !defaults.bool(forKey: Key.loginItemConfigured) {
            defaults.set(true, forKey: Key.loginItemConfigured)
            // didSet doesn't run inside init, so register directly.
            do {
                try SMAppService.mainApp.register()
            } catch {
                Log.engine.error("Login item registration failed: \(error.localizedDescription, privacy: .public)")
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } else if installed && launchAtLogin && defaults.string(forKey: Key.loginItemPath) != Bundle.main.bundlePath {
            // The app was moved (e.g. ~/Applications → /Applications): point the login item at this copy.
            try? SMAppService.mainApp.unregister()
            do {
                try SMAppService.mainApp.register()
            } catch {
                Log.engine.error("Login item re-registration failed: \(error.localizedDescription, privacy: .public)")
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        if installed && launchAtLogin { defaults.set(Bundle.main.bundlePath, forKey: Key.loginItemPath) }
    }

    func toggleTrigger(_ trigger: SwitchTrigger) {
        if triggers.contains(trigger) { triggers.remove(trigger) } else { triggers.insert(trigger) }
    }

    // MARK: - Shortcuts

    /// Assigning a shortcut already used by another action moves it here.
    func setShortcut(_ shortcut: Shortcut?, for action: HotkeyAction) {
        var updated = shortcuts
        if let shortcut {
            for (other, existing) in updated where other != action && existing == shortcut {
                updated[other] = nil
            }
        }
        updated[action] = shortcut
        shortcuts = updated
    }

    func resetShortcuts() {
        shortcuts = Self.loadShortcuts(nil)
    }

    /// Stored as {action: shortcut or null}; an action missing from storage gets its default.
    private static func loadShortcuts(_ data: Data?) -> [HotkeyAction: Shortcut] {
        let stored = data.flatMap { try? JSONDecoder().decode([String: Shortcut?].self, from: $0) } ?? [:]
        var result: [HotkeyAction: Shortcut] = [:]
        for action in HotkeyAction.allCases {
            let shortcut = stored[action.rawValue] ?? action.defaultShortcut
            if let shortcut { result[action] = shortcut }
        }
        return result
    }

    private func saveShortcuts() {
        let stored = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0.rawValue, shortcuts[$0]) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Key.shortcuts)
        }
    }

    // MARK: - Exceptions

    /// Adds a word as typed ("ye", "npm"); returns false for empty input or a duplicate.
    @discardableResult
    func addException(_ input: String) -> Bool {
        let word = TextRules.coreWord(input.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
        guard !word.isEmpty, !exceptions.contains(word) else { return false }
        exceptions = (exceptions + [word]).sorted()
        return true
    }

    func removeException(_ word: String) {
        exceptions.removeAll { $0 == word }
    }

    /// Counts reverts of Klavko's fixes per word, across restarts.
    /// Returns true on the second revert of a word the user hasn't already declined to add.
    func recordRevert(of word: String) -> Bool {
        let key = word.lowercased()
        guard !exceptions.contains(key),
              !(defaults.stringArray(forKey: Key.declinedExceptions) ?? []).contains(key) else { return false }
        var counts = defaults.dictionary(forKey: Key.revertCounts) as? [String: Int] ?? [:]
        counts[key, default: 0] += 1
        // Keep only a handful of recent words; this is a hint, not a history.
        if counts.count > 200, let stale = counts.min(by: { $0.value < $1.value })?.key, stale != key {
            counts[stale] = nil
        }
        let offer = counts[key, default: 0] >= 2
        if offer { counts[key] = nil }
        defaults.set(counts, forKey: Key.revertCounts)
        return offer
    }

    /// "No" to the offer: don't ask about this word again.
    func declineException(_ word: String) {
        var declined = defaults.stringArray(forKey: Key.declinedExceptions) ?? []
        declined.append(word.lowercased())
        defaults.set(declined, forKey: Key.declinedExceptions)
    }

    // MARK: - Replacements

    /// Adds or updates a replacement; false if either side is empty.
    @discardableResult
    func setReplacement(from: String, to: String) -> Bool {
        let from = from.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !to.isEmpty else { return false }
        var updated = replacements.filter { $0.from != from }
        updated.append(Replacement(from: from, to: to))
        replacements = updated
        return true
    }

    func removeReplacement(_ replacement: Replacement) {
        replacements.removeAll { $0 == replacement }
    }

    // MARK: - Excluded apps

    func isExcluded(_ bundleID: String) -> Bool {
        excludedApps.contains(bundleID)
    }

    func toggleExcluded(_ bundleID: String) {
        if isExcluded(bundleID) {
            excludedApps.removeAll { $0 == bundleID }
        } else {
            excludedApps.append(bundleID)
        }
    }
}
