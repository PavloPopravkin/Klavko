import AppKit
import FluidAudio
import ApplicationServices
import Carbon
import KlavkoCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private let recorder = ShortcutRecorder()
    private let engine = SwitchEngine()
    private let exceptionPrompt = ExceptionPrompt()
    private let correctionWatcher = VoiceCorrectionWatcher()
    private let learnPrompt = VoiceLearnPrompt()
    private let clipboard = ClipboardManager()
    private lazy var clipboardWindow = ClipboardWindow(manager: clipboard)
    private let translator = Translator()
    private let dictation = VoiceDictation()
    private let parakeet = ParakeetEngine()
    private var monitor: KeyboardMonitor?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?
    private var watchdogTimer: Timer?
    private var flagTimer: Timer?
    private var shownLayoutID: String?
    private var secureInputActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        engine.isPaused = { [unowned self] in
            MainActor.assumeIsolated { recorder.recording != nil }
        }
        engine.isExcluded = { [unowned self] in
            MainActor.assumeIsolated {
                guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
                return settings.isExcluded(bundleID)
            }
        }
        engine.appContinuesLists = {
            guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
            return Self.appsWithOwnLists.contains(bundleID)
        }
        dictation.languages = { [unowned self] in
            settings.voiceLanguage == "auto" ? ["uk", "en"] : [settings.voiceLanguage]
        }
        // Between two plausible results, the one in the layout's language.
        dictation.preferredLanguage = { SystemLayouts.currentLanguage() ?? "uk" }
        dictation.vocabulary = { [unowned self] in settings.voiceRules }
        dictation.onInserted = { [unowned self] text in
            engine.reset()
            if settings.offerVoiceCorrections { correctionWatcher.watch(inserted: text) }
        }
        // A dictated word fixed by hand: offer to spell it that way from now on.
        correctionWatcher.known = { [unowned self] in settings.voiceRules }
        // One word at a time: only the first correction is offered.
        correctionWatcher.onFound = { [unowned self] corrections in
            guard let first = corrections.first else { return }
            learnPrompt.show([first]) { [unowned self] in
                settings.setVoiceSpelling(heard: first.from, written: first.to)
            }
        }
        engine.onUserKey = { [unowned self] in
            MainActor.assumeIsolated { correctionWatcher.userTyped() }
        }
        // Used once its model is downloaded (opt-in, from Settings → Voice input); macOS recognition until then.
        dictation.parakeet = parakeet
        clipboard.isEnabled = { [unowned self] in settings.clipboardEnabled }
        clipboard.keepDays = { [unowned self] in settings.clipboardKeepDays }
        clipboard.ignoredApps = { [unowned self] in settings.clipboardIgnoredApps }
        clipboard.onCopied = { [unowned self] in
            if settings.playCopySound { playSound(named: settings.copySoundName) }
        }
        clipboard.prune()
        clipboard.start()
        engine.onClipboard = { [unowned self] in
            MainActor.assumeIsolated { clipboardWindow.toggle() }
        }
        engine.onTranslate = { [unowned self] in
            MainActor.assumeIsolated { translator.start() }
        }
        engine.onVoice = { [unowned self] in
            MainActor.assumeIsolated { dictation.toggle() }
        }
        engine.onReturn = { [unowned self] in
            MainActor.assumeIsolated {
                if dictation.handleReturn() { return true }
                // "Remember this spelling?" on screen: Return confirms it first (and doesn't reach the app).
                if learnPrompt.isVisible {
                    learnPrompt.confirm()
                    return true
                }
                // Return may send the message and empty the field: look at the corrections first.
                correctionWatcher.checkNow()
                return false
            }
        }
        engine.onEscape = { [unowned self] in
            MainActor.assumeIsolated {
                // "Remember this spelling?" on screen: Esc declines it (and doesn't reach the app).
                if learnPrompt.isVisible {
                    learnPrompt.close()
                    return true
                }
                guard dictation.isActive else { return false }
                dictation.cancel()
                return true
            }
        }
        engine.onFix = { [unowned self] kind in
            MainActor.assumeIsolated { playFixSound(kind) }
        }
        engine.onRevert = { [unowned self] word in
            MainActor.assumeIsolated {
                guard settings.recordRevert(of: word) else { return }
                Log.engine.notice("Offering to add a reverted word to exceptions")
                exceptionPrompt.show(word: word,
                                     onAdd: { [unowned self] in settings.addException(word) },
                                     onDecline: { [unowned self] in settings.declineException(word) })
            }
        }
        settings.onChange = { [unowned self] in applySettings() }
        applySettings()
        engine.reloadLayouts()
        // Load the dictionaries and sounds now, not on the first word typed.
        DispatchQueue.main.async { [weak self, engine] in
            engine.warmUp()
            guard let self else { return }
            soundPlayer.preload(settings.soundName)
            soundPlayer.preload(settings.spellingSoundName)
            soundPlayer.preload(settings.copySoundName)
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.reloadLayouts() }
            }
        // Flag in the menu bar follows the active layout.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFlag() }
            }
        // Typing in another app starts from scratch.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.reset() }
            }

        monitor = KeyboardMonitor { [weak self, engine] type, event in
            let pass = engine.handle(type, event)
            // The layout notification sometimes doesn't arrive; layout shortcuts are key events, so check after them.
            if type == .keyDown || type == .flagsChanged {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshFlag() } }
            }
            return pass
        }
        startMonitoring(prompt: true)

        // Developer check of the exception card's look: open Klavko with --demo-exception-prompt.
        if CommandLine.arguments.contains("--demo-exception-prompt") {
            exceptionPrompt.show(word: "ghbdsn", onAdd: {}, onDecline: {})
        }
        // Developer check of speech recognition: --voice-check <audio file> <output.txt>.
        if let index = CommandLine.arguments.firstIndex(of: "--voice-check"), index + 2 < CommandLine.arguments.count {
            let file = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task { [parakeet] in
                var report = await VoiceDictation.check(file: file)
                for (name, hint) in [("parakeet auto", nil), ("parakeet uk-only", Language.ukrainian)] as [(String, Language?)] {
                    let started = Date()
                    let text = (try? await parakeet.transcribe(file: file, language: hint)) ?? "(failed)"
                    let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
                    report += "\n\(name) [\(seconds) s, russian=\(LanguageGuess.looksRussian(text))]: \(text)"
                }
                try? report.write(to: output, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
        // Developer check of the voice indicator: --snapshot-voice <file.png>.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-voice"), index + 1 < CommandLine.arguments.count {
            dictation.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            NSApp.terminate(nil)
        }
        // Developer check of the translator: --translate-check <text> <out.txt> writes the translation and quits.
        if let index = CommandLine.arguments.firstIndex(of: "--translate-check"), index + 2 < CommandLine.arguments.count {
            translator.check(CommandLine.arguments[index + 1], writeTo: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
        }
        // Developer check of the clipboard window: --snapshot-clipboard <file.png>.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-clipboard"), index + 1 < CommandLine.arguments.count {
            clipboardWindow.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        // Developer check of the "remember this spelling?" card: --snapshot-learn <file.png>.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-learn"), index + 1 < CommandLine.arguments.count {
            VoiceLearnPrompt.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            NSApp.terminate(nil)
        }
        // Developer check of the settings layout: --snapshot-settings <file.png> renders the window and quits.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-settings"),
           index + 1 < CommandLine.arguments.count {
            snapshotSettings(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }

        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdog() }
        }
        // Layout changed by the mouse (Input menu) or another app: no key event to catch it.
        flagTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFlag() }
        }
    }

    private func applySettings() {
        engine.config = SwitchEngine.Config(shortcuts: settings.shortcuts,
                                            autoSwitch: settings.isEnabled,
                                            triggers: settings.triggers,
                                            switchWhileTyping: settings.switchWhileTyping,
                                            backspaceUndo: settings.backspaceUndo,
                                            convertAbbreviations: settings.convertAbbreviations,
                                            correctSpelling: settings.correctSpelling,
                                            spaceAfterPunctuation: settings.spaceAfterPunctuation,
                                            autoCapitalize: settings.autoCapitalize,
                                            typography: settings.typography,
                                            listContinuation: settings.listContinuation,
                                            replacements: settings.replacements,
                                            exceptions: Set(settings.exceptions))
        updateIcon()
    }

    // MARK: - Sound

    private let soundPlayer = SoundPlayer()

    private func playFixSound(_ kind: FixKind) {
        switch kind {
        case .layout where settings.playSound: playSound(named: settings.soundName)
        case .spelling where settings.playSpellingSound: playSound(named: settings.spellingSoundName)
        default: break
        }
    }

    private func playSound(named name: String) {
        soundPlayer.play(name)
    }

    // MARK: - Permissions and health

    private func startMonitoring(prompt: Bool) {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(options), monitor?.start() == true {
            permissionTimer?.invalidate()
            permissionTimer = nil
            updateIcon()
            return
        }
        guard permissionTimer == nil else { return }
        // Wait until the user grants access in System Settings.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startMonitoring(prompt: false) }
        }
        updateIcon()
    }

    private func watchdog() {
        monitor?.ensureEnabled()

        // While another app holds Secure Input (password fields, "Secure Keyboard Entry"),
        // macOS hides all keystrokes from Klavko.
        let secure = IsSecureEventInputEnabled()
        if secure != secureInputActive {
            secureInputActive = secure
            Log.monitor.notice("Secure input \(secure ? "on" : "off", privacy: .public), owner: \(Self.secureInputOwner() ?? "-", privacy: .public)")
            updateIcon()
        }
    }

    private static func secureInputOwner() -> String? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? Int32 ?? (session["kCGSSessionSecureInputPID"] as? Int).map(Int32.init),
              let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.localizedName ?? app.bundleIdentifier
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabledItem("Klavko"))

        if monitor?.isRunning != true {
            menu.addItem(.separator())
            menu.addItem(item("⚠️ Надайте доступ у «Універсальний доступ»…", #selector(openAccessibilitySettings)))
        } else if secureInputActive {
            menu.addItem(.separator())
            let owner = Self.secureInputOwner().map { "«\($0)»" } ?? "іншій програмі"
            menu.addItem(disabledItem("⚠️ Захищене введення в \(owner)"))
            menu.addItem(disabledItem("     Klavko зараз не бачить клавіатуру"))
        }

        menu.addItem(.separator())
        let toggle = item("Автоматично виправляти розкладку", #selector(toggleEnabled))
        toggle.state = settings.isEnabled ? .on : .off
        menu.addItem(toggle)
        let spelling = item("Виправляти помилки", #selector(toggleSpelling))
        spelling.state = settings.correctSpelling ? .on : .off
        menu.addItem(spelling)

        if let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier,
           bundleID != Bundle.main.bundleIdentifier {
            let exclude = item("Не виправляти в «\(app.localizedName ?? bundleID)»", #selector(toggleExcluded(_:)))
            exclude.representedObject = bundleID
            exclude.state = settings.isExcluded(bundleID) ? .on : .off
            menu.addItem(exclude)
        }

        menu.addItem(.separator())
        menu.addItem(item("Голосовий ввід", #selector(toggleVoice)))
        menu.addItem(item("Перекласти виділене", #selector(startTranslation)))
        menu.addItem(item("Історія буфера обміну", #selector(showClipboard)))
        menu.addItem(item("Налаштування…", #selector(showSettings), key: ","))
        menu.addItem(item("Вийти з Klavko", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
    }

    @objc private func toggleSpelling() {
        settings.correctSpelling.toggle()
    }

    @objc private func toggleExcluded(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        settings.toggleExcluded(bundleID)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, recorder: recorder, parakeet: parakeet, clipboard: clipboard,
                                    keyLayout: englishLayout(),
                                    previewSound: { [weak self] name in self?.playSound(named: name) })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Klavko — Налаштування"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Renders every tab into `<name>-<tab>.png` next to `url`, then quits.
    private func snapshotSettings(to url: URL, tabs: [SettingsTab] = SettingsTab.allCases) {
        guard let tab = tabs.first else { return NSApp.terminate(nil) }
        var view = SettingsView(settings: settings, recorder: recorder, parakeet: parakeet, clipboard: clipboard,
                                    keyLayout: englishLayout(),
                                previewSound: { _ in })
        view.initialTab = tab
        view.height = 900
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.orderBack(nil)
        settingsWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if let view = self?.settingsWindow?.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let name = url.deletingPathExtension().lastPathComponent + "-\(tab.rawValue).png"
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: url.deletingLastPathComponent().appendingPathComponent(name))
            }
            self?.settingsWindow?.close()
            self?.snapshotSettings(to: url, tabs: Array(tabs.dropFirst()))
        }
    }

    @objc private func toggleVoice() {
        // After the menu closes, so the text lands in the app that was in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.dictation.toggle() }
    }

    @objc private func showClipboard() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.clipboardWindow.show() }
    }

    @objc private func startTranslation() {
        // The menu has taken focus from the app with the selection; give it back first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.translator.start() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func englishLayout() -> LayoutMap? {
        SystemLayouts.enabledLayouts().first { $0.map.language == "en" }?.map
    }

    private static let flags = ["uk": "🇺🇦", "en": "🇺🇸"]

    /// Apps that continue "- " and "1." lists themselves.
    private static let appsWithOwnLists: Set<String> = [
        "com.apple.Notes", "com.apple.iWork.Pages", "com.microsoft.Word", "com.microsoft.onenote.mac",
        "notion.id", "md.obsidian", "com.tinyspeck.slackmacgap", "net.shinyfrog.bear", "com.lukilabs.lukiapp",
    ]

    private func refreshFlag() {
        let current = SystemLayouts.currentLayoutID()
        guard current != shownLayoutID else { return }
        updateIcon()
    }

    private func updateIcon() {
        guard let item = statusItem, let button = item.button else { return }
        shownLayoutID = SystemLayouts.currentLayoutID()
        button.appearsDisabled = !settings.isEnabled

        // Problems take priority over the flag.
        let warning: String? = monitor?.isRunning != true ? "keyboard.badge.exclamationmark"
            : secureInputActive ? "lock.circle" : nil
        if warning == nil, settings.showFlag, let language = SystemLayouts.currentLanguage() {
            item.length = NSStatusItem.variableLength
            button.image = nil
            button.title = Self.flags[language] ?? language.uppercased()
            button.font = Self.flags[language] == nil ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 15)
            return
        }

        item.length = NSStatusItem.squareLength
        button.title = ""
        let image = NSImage(systemSymbolName: warning ?? "keyboard", accessibilityDescription: "Klavko")
            ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Klavko")
        image?.isTemplate = true
        button.image = image
    }
}
