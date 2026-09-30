import AVFoundation
import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Short spoken replies after a command ("Opening Music", "Playing Purple Rain by Prince"), in the
/// same open-source Kokoro voice as onboarding, synthesized on this Mac. The voice model (~120 MB)
/// downloads in the background after launch; until it's ready, replies are simply shown, not spoken.
@MainActor
enum Voice {
    static var enabled: Bool { Pref.bool(Pref.speakReplies) }

    private static var player: AVAudioPlayer?
    private static var speaking: Task<Void, Never>?

    static func prepare() {
        guard enabled else { return }
        #if canImport(FluidAudio)
        Task.detached(priority: .utility) { try? await KokoroVoice.shared.prepare() }
        #endif
    }

    static func say(_ text: String?) {
        guard enabled, let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        #if canImport(FluidAudio)
        speaking?.cancel()
        speaking = Task {
            // Spelled as two words so Kokoro says the name right.
            let line = text.replacingOccurrences(of: Brand.name, with: "Open Notch")
            guard let wav = try? await KokoroVoice.shared.wav(line), !Task.isCancelled else { return }
            player?.stop()
            player = try? AVAudioPlayer(data: wav)
            player?.play()
        }
        #endif
    }

    /// Stops talking, e.g. when the user starts speaking so the mic doesn't hear us.
    static func stop() {
        speaking?.cancel()
        player?.stop()
    }
}

#if canImport(FluidAudio)
actor KokoroVoice {
    static let shared = KokoroVoice()
    private var manager: KokoroAneManager?

    func prepare() async throws {
        guard manager == nil else { return }
        let m = KokoroAneManager()
        try await m.initialize()
        // The first synthesis warms the pipeline (~1 s); after that a reply takes ~0.1 s.
        _ = try? await m.synthesize(text: "Ready.")
        manager = m
    }

    /// Nil until the model is ready; never waits on the download.
    func wav(_ text: String) async throws -> Data? {
        guard let manager else { return nil }
        return try await manager.synthesize(text: text)
    }
}
#endif
