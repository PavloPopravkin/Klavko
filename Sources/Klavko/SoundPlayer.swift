import AVFoundation

/// Plays Klavko's short sounds at its own volume, off the main thread:
/// starting a sound takes 20–130 ms, which must not delay the key being typed.
/// (System alert sounds start instantly, but follow the system alert volume, which may be muted.)
final class SoundPlayer {
    private let queue = DispatchQueue(label: "app.klavko.sound", qos: .userInitiated)
    private var players: [String: AVAudioPlayer] = [:]
    private let volume: Float = 0.4

    func play(_ name: String) {
        queue.async { [self] in
            guard let player = player(for: name) else { return }
            player.stop()
            player.currentTime = 0
            if !player.play() {
                Log.engine.error("Sound \(name, privacy: .public) didn't start")
            }
        }
    }

    /// Loads a sound ahead of time, so the first fix doesn't wait for it.
    func preload(_ name: String) {
        queue.async { [self] in _ = player(for: name) }
    }

    /// Only on `queue`.
    private func player(for name: String) -> AVAudioPlayer? {
        if let player = players[name] { return player }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            Log.engine.error("Sound \(name, privacy: .public) couldn't be loaded")
            return nil
        }
        player.volume = volume
        player.prepareToPlay()
        players[name] = player
        return player
    }
}
