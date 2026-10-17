import AppKit
import KlavkoCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var recorder: ShortcutRecorder
    @ObservedObject var parakeet: ParakeetEngine
    /// English layout, used to name letter keys in shortcuts.
    let keyLayout: LayoutMap?
    let previewSound: (String) -> Void
    /// Taller only for a full-length snapshot of the window.
    var height: CGFloat = 620

    @State private var newException = ""
    @State private var newReplacementFrom = ""
    @State private var newReplacementTo = ""
    @State private var newSpellingHeard = ""
    @State private var newSpellingWritten = ""
    @State private var tab: SettingsTab = .general
    /// The tab shown first (for snapshots).
    var initialTab: SettingsTab = .general

    private func addException() {
        // Several words at once: "npm, ye ок".
        let words = newException.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" })
        for word in words { settings.addException(String(word)) }
        newException = ""
    }

    private func addSpelling() {
        if settings.setVoiceSpelling(heard: newSpellingHeard, written: newSpellingWritten) {
            newSpellingHeard = ""
            newSpellingWritten = ""
        }
    }

    private func addReplacement() {
        if settings.setReplacement(from: newReplacementFrom, to: newReplacementTo) {
            newReplacementFrom = ""
            newReplacementTo = ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $tab)
            Divider()
            Form {
                switch tab {
                case .general:
                    Section {
                        Toggle("Запускати під час входу в систему", isOn: $settings.launchAtLogin)
                        Toggle("Показувати прапор розкладки в меню", isOn: $settings.showFlag)
                        soundRow("Звук під час зміни розкладки", isOn: $settings.playSound, sound: $settings.soundName)
                        soundRow("Звук під час виправлення помилок", isOn: $settings.playSpellingSound,
                                 sound: $settings.spellingSoundName)
                    }

                    Section("Не виправляти автоматично в програмах") {
                        if settings.excludedApps.isEmpty {
                            Text("Немає").foregroundStyle(.secondary)
                        }
                        ForEach(settings.excludedApps, id: \.self) { bundleID in
                            HStack {
                                Text(Self.appName(bundleID))
                                Spacer()
                                Button("Прибрати") { settings.toggleExcluded(bundleID) }
                            }
                        }
                    }

                case .layout:
                    Section {
                        Toggle("Автоматично виправляти розкладку", isOn: $settings.isEnabled)
                        Toggle("Перемикати вже під час набору слова", isOn: $settings.switchWhileTyping)
                            .disabled(!settings.isEnabled)
                        Toggle("Перемикати слова з великих літер (абревіатури)", isOn: $settings.convertAbbreviations)
                            .disabled(!settings.isEnabled)
                        HStack {
                            Text("Перевіряти слово після")
                            Spacer()
                            ForEach(SwitchTrigger.allCases, id: \.self) { trigger in
                                ChipToggle(title: trigger.title, isOn: settings.triggers.contains(trigger)) {
                                    settings.toggleTrigger(trigger)
                                }
                            }
                        }
                        Toggle("Backspace одразу після виправлення скасовує його", isOn: $settings.backspaceUndo)
                    } header: {
                        Text("Автоматичне перемикання розкладки")
                    } footer: {
                        Text("Гарячі клавіші працюють, навіть коли автоматичні виправлення вимкнені.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        HStack {
                            TextField("", text: $newException, prompt: Text("Нові слова через пробіл або кому"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addException)
                            Button("Додати", action: addException)
                                .disabled(newException.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if settings.exceptions.isEmpty {
                            Text("Поки порожньо").foregroundStyle(.secondary)
                        } else {
                            FlowLayout(spacing: 6) {
                                ForEach(settings.exceptions, id: \.self) { word in
                                    RemovableChip(title: word) { settings.removeException(word) }
                                }
                            }
                        }
                    } header: {
                        Text("Винятки (\(settings.exceptions.count))")
                    } footer: {
                        Text("Слова, які Klavko ніколи не змінює. Записуйте так, як набираєте їх (наприклад «ye» або «npm»). "
                             + "Якщо ви двічі скасуєте виправлення одного слова, Klavko сам запропонує додати його сюди.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .text:
                    Section {
                        Toggle(isOn: $settings.correctSpelling) {
                            Text("Виправляти помилки")
                            Text("Українська та англійська: пропущені й переставлені літери, сусідні клавіші "
                                 + "(рлбиш → робиш), залипання Shift (ПРивіт → Привіт). "
                                 + "Сумнівні слова, імена посеред речення та слова з цифрами не змінюються.")
                        }
                        Toggle(isOn: $settings.spaceAfterPunctuation) {
                            Text("Додавати пропущений пробіл після розділових знаків")
                            Text("«Привіт,як» → «Привіт, як». Після крапки — лише перед великою літерою; "
                                 + "числа, адреси, дефіс, дужки й лапки не змінюються.")
                        }
                    } header: {
                        Text("Помилки")
                    }

                    Section {
                        Toggle(isOn: $settings.autoCapitalize) {
                            Text("Велика літера на початку речення")
                            Text("Після «.» «!» «?», на новому рядку та на початку тексту. Скорочення («т.д.», «напр.») не враховуються.")
                        }
                        Toggle(isOn: $settings.typography) {
                            Text("Типографські символи")
                            Text("... → …   \" → « » (укр.) / “ ” (англ.)   « - » → « — »   (c) (r) (tm) → © ® ™")
                        }
                        Toggle(isOn: $settings.listContinuation) {
                            Text("Продовжувати списки")
                            Text("Enter після «- пункт» або «1. пункт» додає наступний маркер; Enter на порожньому пункті завершує список. "
                                 + "Не діє в програмах, що роблять це самі (Нотатки, Word, Notion…).")
                        }
                        // Fields without labels: in a Form a label would take a column of its own and push the field aside.
                        HStack(spacing: 8) {
                            TextField("", text: $newReplacementFrom, prompt: Text("Набираю"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("", text: $newReplacementTo, prompt: Text("Замінити на"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addReplacement)
                            Button("Додати", action: addReplacement)
                                .disabled(newReplacementFrom.trimmingCharacters(in: .whitespaces).isEmpty || newReplacementTo.isEmpty)
                        }
                        if !settings.replacements.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(settings.replacements, id: \.self) { rule in
                                    RemovableChip(title: "\(rule.from) → \(rule.to)") { settings.removeReplacement(rule) }
                                }
                            }
                        }
                    } header: {
                        Text("Оформлення тексту")
                    } footer: {
                        Text("Власні заміни: слово («сп» → «спасибі») змінюється, коли воно закінчене; "
                             + "послідовність символів («:)» → «🙂») — щойно набрана.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .voice:
                    Section {
                        Picker("Я говорю", selection: $settings.voiceLanguage) {
                            Text("Українською та англійською").tag("auto")
                            Text("Лише українською").tag("uk")
                            Text("Лише англійською").tag("en")
                        }
                        HStack {
                            Text("Модель розпізнавання")
                            Spacer()
                            switch parakeet.state {
                            case .ready:
                                Label("Parakeet Ultra готова", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            case .downloading(let fraction):
                                ProgressView(value: fraction).frame(width: 120)
                                Text("\(Int(fraction * 100)) %").monospacedDigit().foregroundStyle(.secondary)
                            case .notDownloaded:
                                Button("Завантажити (~600 МБ)") { parakeet.prepare() }
                            case .failed(let message):
                                Text(message).foregroundStyle(.red).lineLimit(2)
                                Button("Ще раз") { parakeet.prepare() }
                            }
                        }
                    } header: {
                        Text("Голосовий ввід")
                    } footer: {
                        Text("Натисніть гарячу клавішу «Голосовий ввід» (за замовчуванням fn), говоріть, натисніть її ще раз — "
                             + "текст з’явиться в місці курсора. Esc скасовує. Розпізнає модель NVIDIA Parakeet Ultra на цьому Mac "
                             + "(з розділовими знаками); російську вона ніколи не вставить — такий результат перевіряє український "
                             + "розпізнавач macOS. Поки модель не завантажена, працює вбудоване розпізнавання macOS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        HStack(spacing: 8) {
                            TextField("", text: $newSpellingHeard, prompt: Text("Чує"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("", text: $newSpellingWritten, prompt: Text("Писати так"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addSpelling)
                            Button("Додати", action: addSpelling)
                                .disabled(newSpellingHeard.trimmingCharacters(in: .whitespaces).isEmpty
                                          || newSpellingWritten.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if settings.voiceVocabulary.isEmpty {
                            Text("Поки порожньо").foregroundStyle(.secondary)
                        } else {
                            FlowLayout(spacing: 6) {
                                ForEach(settings.voiceVocabulary, id: \.self) { rule in
                                    RemovableChip(title: "\(rule.from) → \(rule.to)") { settings.removeVoiceSpelling(rule) }
                                }
                            }
                        }
                    } header: {
                        Text("Словник голосового вводу (\(settings.voiceVocabulary.count))")
                    } footer: {
                        Text("Як писати слова, які розпізнавання чує інакше. Виправте надиктоване слово вручну — Klavko "
                             + "запропонує запам’ятати виправлення (5 секунд, кнопка «Підтвердити»). Власні заміни з вкладки "
                             + "«Текст» («адра» → «ADRA») теж діють для голосового вводу.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .hotkeys:
                    Section {
                        ForEach(HotkeyAction.allCases, id: \.self) { action in
                            shortcutRow(action)
                        }
                        Button("Відновити стандартні") { settings.resetShortcuts() }
                    } header: {
                        Text("Гарячі клавіші")
                    } footer: {
                        Text("Клацніть на комбінацію і натисніть нову: клавішу з ⌃ ⌥ ⇧ ⌘, лише модифікатори разом "
                             + "(наприклад ⌥⌘) або двічі швидко ті самі модифікатори. Esc — скасувати. "
                             + "Якщо нічого не виділено, змінюється весь текст, набраний після останнього кліку, Enter чи стрілок.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 600, height: height)
        .onAppear { tab = initialTab }
        .onDisappear { recorder.stop() }
    }

    private func soundRow(_ title: String, isOn: Binding<Bool>, sound: Binding<String>) -> some View {
        // Switch at the right edge, like every other row.
        HStack {
            Text(title)
            Spacer()
            Picker("", selection: sound) {
                ForEach(Settings.sounds, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 100)
            .disabled(!isOn.wrappedValue)
            Button {
                previewSound(sound.wrappedValue)
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .help("Прослухати")
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func shortcutRow(_ action: HotkeyAction) -> some View {
        HStack {
            Text(action.title)
            Spacer()
            Button {
                if recorder.recording == action {
                    recorder.stop()
                } else {
                    recorder.start(action) { settings.setShortcut($0, for: action) }
                }
            } label: {
                if recorder.recording == action {
                    Text("Натисніть…")
                        .foregroundStyle(Color.accentColor)
                } else if let shortcut = settings.shortcuts[action] {
                    HStack(spacing: 4) {
                        ForEach(Array(shortcut.parts(layout: keyLayout).enumerated()), id: \.offset) { _, part in
                            Keycap(text: part)
                        }
                    }
                } else {
                    Text("Не задано").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Клацніть, щоб змінити")

            Button {
                settings.setShortcut(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Прибрати гарячу клавішу")
            .opacity(settings.shortcuts[action] == nil ? 0 : 1)
            .disabled(settings.shortcuts[action] == nil)
        }
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

enum SettingsTab: String, CaseIterable {
    case general, layout, text, voice, hotkeys

    var title: String {
        switch self {
        case .general: "Загальні"
        case .layout: "Розкладка"
        case .text: "Текст"
        case .voice: "Голос"
        case .hotkeys: "Клавіші"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .layout: "keyboard"
        case .text: "textformat"
        case .voice: "waveform"
        case .hotkeys: "command"
        }
    }
}

/// Icons with titles in a row at the top, like the tabs of macOS settings windows.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18, weight: .regular))
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.system(size: 11))
                    }
                    .frame(width: 84, height: 50)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(selection == tab ? Color.primary.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Dark rounded key label, like "Double", "⌥", "Space".
private struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.78)))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
    }
}

/// On/off chip for a set of options.
private struct ChipToggle: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.25)))
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// A word with a × to remove it.
private struct RemovableChip: View {
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Прибрати «\(title)»")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.18)))
    }
}

/// Lays children out left to right, wrapping onto new lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty && row.width + spacing + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(Row(y: y))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
