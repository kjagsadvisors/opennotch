#if canImport(FluidAudio)
import AVFoundation
import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT (0.6B) on the Apple Neural Engine, via FluidAudio.
/// Transcribes about 100x faster than real time, with punctuation and capitalization built in.
actor ParakeetEngine {
    static let shared = ParakeetEngine()

    private var manager: AsrManager?
    private var decoderLayers = 2

    /// Parakeet needs at least this much audio; shorter clips are padded with silence.
    private static let minimumSamples = 16_000

    var isReady: Bool { manager != nil }

    private static var version: AsrModelVersion {
        switch Pref.string(Pref.parakeetModel) {
        case "redux": return .redux
        case "v3": return .v3
        default: return .ultra
        }
    }

    /// Downloads the model once (cached in Application Support), then loads it onto the Neural Engine.
    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: Self.version)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        decoderLayers = models.version.decoderLayers
        manager = m
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw ASRError.notInitialized }
        var audio = samples
        if audio.count < Self.minimumSamples { audio += [Float](repeating: 0, count: Self.minimumSamples - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribe(file url: URL) async throws -> String {
        try await prepare()
        guard let manager else { throw ASRError.notInitialized }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        return try await manager.transcribe(url, decoderState: &state).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Collects 16 kHz audio while the key is held. Parakeet is batch, but fast enough to re-run on
/// everything heard so far about once a second, which gives the notch a live transcript.
final class ParakeetSession: DictationSession {
    var onUpdate: ((String) -> Void)?

    private let lock = NSLock()
    private var samples: [Float] = []
    private var previewTask: Task<Void, Never>?
    private var finished = false

    func start() {
        previewTask = Task { [weak self] in
            var lastCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard let self, !Task.isCancelled else { return }
                let snapshot = self.snapshot()
                // Wait for at least a second of new speech before previewing again.
                guard snapshot.count - lastCount >= 16_000 else { continue }
                lastCount = snapshot.count
                if let text = try? await ParakeetEngine.shared.transcribe(snapshot), !text.isEmpty, !self.isFinished {
                    DispatchQueue.main.async { self.onUpdate?(text) }
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func finish() async -> String {
        markFinished()
        previewTask?.cancel()
        let audio = snapshot()
        guard !audio.isEmpty else { return "" }
        do {
            return try await ParakeetEngine.shared.transcribe(audio)
        } catch {
            debugLog("parakeet transcribe: \(error)")
            return ""
        }
    }

    func cancel() {
        markFinished()
        previewTask?.cancel()
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    private func markFinished() {
        lock.lock(); finished = true; lock.unlock()
    }

    private func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}
#endif
