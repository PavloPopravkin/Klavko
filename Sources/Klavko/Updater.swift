import AppKit
import CryptoKit
import KlavkoCore
import SwiftUI

/// Updates from the project's GitHub releases: checks the latest release now and then, offers it,
/// and on "Update" downloads the archive, checks it (SHA-256 from GitHub, bundle id, version, code
/// signature), swaps it in place of the running app and starts the new version.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let notes: String
        let archive: URL
        let sha256: String?
        let page: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheck: Date?

    var autoCheck: () -> Bool = { true }
    var skippedVersion: () -> String? = { nil }
    /// A newer version was found by an automatic check (not skipped by the user).
    var onAvailable: (Release) -> Void = { _ in }

    static let latestRelease = URL(string: "https://api.github.com/repos/stepsergius/Klavko/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/stepsergius/Klavko/releases/latest")!

    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var available: Release? {
        switch state {
        case .available(let release), .installing(let release): release
        default: nil
        }
    }

    /// First check shortly after launch, then every six hours.
    func start() {
        timer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.automaticCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.automaticCheck() }
        }
    }

    private func automaticCheck() {
        guard autoCheck() else { return }
        if case .installing = state { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        if case .installing = state { return }
        state = .checking
        do {
            var request = URLRequest(url: Self.latestRelease, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server }
            let release = try Self.parse(data)
            lastCheck = Date()
            if AppVersion.isNewer(release.version, than: currentVersion) {
                state = .available(release)
                Log.engine.notice("Update available: \(release.version, privacy: .public)")
                if !userInitiated && skippedVersion() != release.version { onAvailable(release) }
            } else {
                state = .upToDate
            }
        } catch {
            state = userInitiated ? .failed(Self.message(for: error)) : .idle
            Log.engine.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func parse(_ data: Data) throws -> Release {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let archive = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
        else { throw UpdateError.noArchive }
        let digest = (asset["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: json["body"] as? String ?? "", archive: archive,
                       sha256: digest, page: page)
    }

    // MARK: - Installing

    /// Downloads, checks and puts the new version in place of this one, then restarts into it.
    func install() {
        guard let release = available else { return }
        state = .installing(release)
        let destination = Bundle.main.bundleURL
        Task {
            do {
                let newApp = try await Self.prepare(release)
                try Self.replace(destination, with: newApp, relaunch: true)
                Log.engine.notice("Installing update \(release.version, privacy: .public); quitting")
                NSApp.terminate(nil)
            } catch {
                state = .failed(Self.message(for: error))
                Log.engine.error("Update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The downloaded, unpacked and verified Klavko.app of `release`, in a temporary folder.
    private static func prepare(_ release: Release) async throws -> URL {
        let (download, response) = try await URLSession.shared.download(from: release.archive)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("klavko-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: download, to: zip)

        if let expected = release.sha256 {
            let data = try Data(contentsOf: zip, options: .mappedIfSafe)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw UpdateError.corrupted }
        }
        let unpacked = work.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard let app = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "Klavko.app" }) else {
            throw UpdateError.noArchive
        }
        let info = Bundle(url: app)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == release.version else { throw UpdateError.wrongApp }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    /// Swaps `newApp` in at `destination` once this process has quit (a small shell script waits for
    /// it), putting the old copy back if the move fails; then optionally opens the new version.
    static func replace(_ destination: URL, with newApp: URL, relaunch: Bool) throws {
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable }
        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        DEST=\(shellQuoted(destination.path))
        NEW=\(shellQuoted(newApp.path))
        /bin/rm -rf "$DEST.old"
        if /bin/mv "$DEST" "$DEST.old"; then
            if /bin/mv "$NEW" "$DEST"; then /bin/rm -rf "$DEST.old"; else /bin/mv "$DEST.old" "$DEST"; fi
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        \(relaunch ? "/usr/bin/open \"$DEST\"" : "")
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.wrongApp }
    }

    /// Developer check: installs the latest release over the app at `destination` (not the running one)
    /// without relaunching, and writes what happened to `report`.
    func installForTest(at destination: URL, report: URL) {
        Task {
            await check(userInitiated: true)
            var result = "state: \(state)"
            if let release = available {
                do {
                    let app = try await Self.prepare(release)
                    try Self.replace(destination, with: app, relaunch: false)
                    result += "\nreplacing \(destination.path) with \(release.version)"
                } catch {
                    result += "\nfailed: \(error)"
                }
            }
            try? result.write(to: report, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private enum UpdateError: Error {
        case server, noArchive, corrupted, wrongApp, notWritable
    }

    private static func message(for error: Error) -> String {
        switch error {
        case UpdateError.corrupted:
            tr("Завантажений файл пошкоджений. Спробуйте ще раз.", "The download is damaged. Please try again.")
        case UpdateError.wrongApp, UpdateError.noArchive:
            tr("Не вдалося перевірити нову версію. Завантажте її зі сторінки релізів.",
               "Couldn’t verify the new version. Download it from the releases page.")
        case UpdateError.notWritable:
            tr("Немає дозволу замінити програму в цій папці. Завантажте нову версію вручну.",
               "No permission to replace the app in this folder. Download the new version manually.")
        default:
            tr("Не вдалося перевірити оновлення. Перевірте з’єднання з інтернетом.",
               "Couldn’t check for updates. Check your internet connection.")
        }
    }
}

/// "A new version is available": a card in the top-right corner. It never activates Klavko.
@MainActor
final class UpdatePrompt {
    private var panel: NSPanel?

    func show(_ release: Updater.Release, current: String, onUpdate: @escaping () -> Void,
              onSkip: @escaping () -> Void) {
        close()
        let view = UpdatePromptView(release: release, current: current,
                                    onUpdate: { [weak self] in self?.close(); onUpdate() },
                                    onLater: { [weak self] in self?.close() },
                                    onSkip: { [weak self] in self?.close(); onSkip() })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel = UpdatePanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class UpdatePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct UpdatePromptView: View {
    let release: Updater.Release
    let current: String
    let onUpdate: () -> Void
    let onLater: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Доступна нова версія Klavko", "A new version of Klavko is available"))
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(release.version) · " + tr("у вас", "you have") + " \(current)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let summary = Self.summary(release.notes) {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(tr("Пропустити", "Skip"), action: onSkip)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(tr("Пізніше", "Later"), action: onLater)
                Button(tr("Оновити", "Update"), action: onUpdate)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// The "what's fixed / what's new" part of the release notes, without Markdown marks.
    static func summary(_ notes: String) -> String? {
        let lines = notes.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let line = lines.first { $0.contains("0.") && ($0.lowercased().contains("виправлено") || $0.lowercased().contains("нове")) }
            ?? lines.first { !$0.isEmpty }
        return line?.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }
}
