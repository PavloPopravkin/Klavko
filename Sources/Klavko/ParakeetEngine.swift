import Foundation
import FluidAudio

/// NVIDIA Parakeet Ultra speech recognition on this Mac (Core ML, Neural Engine), via FluidAudio.
/// The model (~600 MB) is downloaded once from Hugging Face; after that everything runs offline.
/// It recognizes 25 European languages including Ukrainian and English, with punctuation and capitals.
@MainActor
final class ParakeetEngine: ObservableObject {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    /// Frees ~1 GB of memory after a while without dictation.
    private var unloadTimer: Timer?

    private static let version: AsrModelVersion = .ultra

    init() {
        let downloaded = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: Self.version), version: Self.version)
        state = downloaded ? .ready : .notDownloaded
    }

    var isDownloaded: Bool { state == .ready }

    /// Downloads (if needed) and loads the model; cheap if it's already loaded.
    @discardableResult
    func prepare() -> Task<AsrManager, Error> {
        unloadTimer?.invalidate()
        if let manager { return Task { manager } }
        if let loading { return loading }
        let task = Task { [weak self] () throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(version: Self.version) { progress in
                Task { @MainActor in
                    if self?.state != .ready { self?.state = .downloading(progress.fractionCompleted) }
                }
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        Task { [weak self] in
            do {
                let manager = try await task.value
                self?.manager = manager
                self?.state = .ready
                Log.engine.notice("Parakeet model ready")
            } catch {
                self?.state = .failed(error.localizedDescription)
                Log.engine.error("Parakeet model failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.loading = nil
        }
        return task
    }

    /// Text of a recording. `language` only rules out the other alphabet (Latin vs Cyrillic).
    func transcribe(file: URL, language: Language?) async throws -> String {
        let manager = try await prepare().value
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(file, decoderState: &state, language: language)
        scheduleUnload()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleUnload() {
        unloadTimer?.invalidate()
        unloadTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.loading == nil, let manager = self.manager else { return }
                Task { await manager.cleanup() }
                self.manager = nil
                Log.engine.notice("Parakeet model unloaded after 10 min idle")
            }
        }
    }
}
