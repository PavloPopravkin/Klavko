import AppKit
import KlavkoCore
import SwiftUI

/// Facts about Klavko shown on the "About" tab; links in one place.
enum AboutInfo {
    static let author = "Serhii Stepaniuk"
    static let email = "stepsergius@gmail.com"
    static let repository = URL(string: "https://github.com/stepsergius/Klavko")!
    /// Where "Thank the author" leads (a jar, Ko-fi, Buy Me a Coffee…); the button is hidden while nil.
    static let donateURL: URL? = URL(string: "https://send.monobank.ua/jar/2CKJVz8jam")

    static var version: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// For bug reports: Klavko and macOS versions.
    static var diagnostics: String {
        "Klavko \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}

/// The "About" tab: what Klavko is, its version and author, a way to say thanks, and what it is built on.
struct AboutSection: View {
    @State private var copied = false

    var body: some View {
        Section {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Klavko").font(.system(size: 22, weight: .bold))
                    Text(tr("Версія", "Version") + " " + AboutInfo.version).foregroundStyle(.secondary)
                    Text(tr("Перемикач розкладки й помічник для набору тексту на Mac: українська та англійська.",
                             "Keyboard layout switcher and typing assistant for Mac: Ukrainian and English."))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
        }

        if let donate = AboutInfo.donateURL {
            Section {
                HStack {
                    Text(tr("Klavko безкоштовний. Якщо він вам допомагає, можна подякувати автору — "
                            + "це допомагає розвивати програму далі.",
                            "Klavko is free. If it helps you, you can thank the author — "
                            + "it helps keep the app growing."))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button {
                        NSWorkspace.shared.open(donate)
                    } label: {
                        Label(tr("Подякувати", "Say Thanks"), systemImage: "heart.fill")
                    }
                    .controlSize(.large)
                    .tint(.pink)
                    .buttonStyle(.borderedProminent)
                }
            } header: {
                Text(tr("Підтримати Klavko", "Support Klavko"))
            }
        }

        Section {
            LabeledContent(tr("Автор", "Author"), value: AboutInfo.author)
            LabeledContent(tr("Пошта", "Email")) {
                Link(AboutInfo.email, destination: URL(string: "mailto:\(AboutInfo.email)?subject=Klavko")!)
            }
            LabeledContent(tr("Код", "Source code")) {
                Link("github.com/stepsergius/Klavko", destination: AboutInfo.repository)
            }
            HStack {
                Text(tr("Знайшли помилку? Напишіть автору й додайте версію програми та macOS.",
                         "Found a bug? Write to the author and include the app and macOS versions."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? tr("Скопійовано", "Copied") : tr("Копіювати версію", "Copy Version")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AboutInfo.diagnostics, forType: .string)
                    copied = true
                }
            }
        } header: {
            Text(tr("Автор і зв’язок", "Author and contact"))
        }

        Section {
            Text(tr("Усе працює на цьому Mac. Набраний текст, надиктоване, переклади й історія буфера обміну нікуди "
                    + "не надсилаються. Інтернет потрібен лише один раз: щоб завантажити модель розпізнавання мовлення "
                    + "(з Hugging Face) і мови для перекладу (від Apple).",
                    "Everything runs on this Mac. What you type, dictate, translate and copy is never sent anywhere. "
                    + "The internet is needed only once: to download the speech recognition model (from Hugging Face) "
                    + "and the translation languages (from Apple)."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(tr("Приватність", "Privacy"))
        }

        Section {
            LabeledContent(tr("Розпізнавання мовлення", "Speech recognition"),
                           value: tr("NVIDIA Parakeet Ultra (CC BY 4.0) через FluidAudio", "NVIDIA Parakeet Ultra (CC BY 4.0) via FluidAudio"))
            LabeledContent(tr("Переклад", "Translation"), value: tr("Перекладач macOS", "macOS translator"))
            LabeledContent(tr("Перевірка правопису", "Spell checking"), value: tr("Словники macOS", "macOS dictionaries"))
        } header: {
            Text(tr("Технології", "Technology"))
        } footer: {
            Text("© 2026 \(AboutInfo.author). " + tr("Klavko безкоштовний.", "Klavko is free."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
