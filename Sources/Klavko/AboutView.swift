import AppKit
import SwiftUI

/// Facts about Klavko shown on the "About" tab; links in one place.
enum AboutInfo {
    static let author = "stepsergius"
    static let email = "stepsergius@gmail.com"
    static let repository = URL(string: "https://github.com/stepsergius/Klavko")!
    /// Where "Thank the author" leads (a jar, Ko-fi, Buy Me a Coffee…); the button is hidden while nil.
    static let donateURL: URL? = nil

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
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
                    Text("Версія \(AboutInfo.version)").foregroundStyle(.secondary)
                    Text("Перемикач розкладки й помічник для набору тексту на Mac: українська та англійська.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
        }

        if let donate = AboutInfo.donateURL {
            Section {
                HStack {
                    Text("Klavko безкоштовний. Якщо він вам допомагає, можна подякувати автору — "
                         + "це допомагає розвивати програму далі.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button {
                        NSWorkspace.shared.open(donate)
                    } label: {
                        Label("Подякувати", systemImage: "heart.fill")
                    }
                    .controlSize(.large)
                    .tint(.pink)
                    .buttonStyle(.borderedProminent)
                }
            } header: {
                Text("Підтримати Klavko")
            }
        }

        Section {
            LabeledContent("Автор", value: AboutInfo.author)
            LabeledContent("Пошта") {
                Link(AboutInfo.email, destination: URL(string: "mailto:\(AboutInfo.email)?subject=Klavko")!)
            }
            LabeledContent("Код") {
                Link("github.com/stepsergius/Klavko", destination: AboutInfo.repository)
            }
            HStack {
                Text("Знайшли помилку? Напишіть автору й додайте версію програми та macOS.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Скопійовано" : "Копіювати версію") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AboutInfo.diagnostics, forType: .string)
                    copied = true
                }
            }
        } header: {
            Text("Автор і зв’язок")
        }

        Section {
            Text("Усе працює на цьому Mac. Набраний текст, надиктоване, переклади й історія буфера обміну нікуди "
                 + "не надсилаються. Інтернет потрібен лише один раз: щоб завантажити модель розпізнавання мовлення "
                 + "(з Hugging Face) і мови для перекладу (від Apple).")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Приватність")
        }

        Section {
            LabeledContent("Розпізнавання мовлення", value: "NVIDIA Parakeet Ultra (CC BY 4.0) через FluidAudio")
            LabeledContent("Переклад", value: "Перекладач macOS")
            LabeledContent("Перевірка правопису", value: "Словники macOS")
        } header: {
            Text("Технології")
        } footer: {
            Text("© 2026 \(AboutInfo.author). Klavko безкоштовний.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
