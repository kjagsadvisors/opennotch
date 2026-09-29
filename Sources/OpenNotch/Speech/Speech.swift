import AVFoundation
import Foundation

/// One hold-to-talk recording being turned into text.
protocol DictationSession: AnyObject {
    /// Called on the main queue with the running transcript, when the engine can provide one.
    var onUpdate: ((String) -> Void)? { get set }
    func start()
    func append(_ buffer: AVAudioPCMBuffer)
    /// Ends the audio and returns the final transcript.
    func finish() async -> String
    func cancel()
}

/// Picks the speech-to-text engine.
///
/// Parakeet (NVIDIA's open model, run on the Neural Engine via FluidAudio) is the default: it's what
/// the popular open-source dictation apps converged on. Apple's SpeechAnalyzer needs no download, so
/// it covers the first minutes while Parakeet downloads, and builds without the FluidAudio package.
enum Speech {
    enum Engine: String {
        case parakeet, apple
    }

    enum ParakeetState: Equatable {
        case unavailable      // built without FluidAudio
        case notDownloaded
        case downloading
        case ready
        case failed(String)
    }

    static var isParakeetBuiltIn: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }

    private(set) static var parakeetState: ParakeetState = isParakeetBuiltIn ? .notDownloaded : .unavailable {
        didSet { DispatchQueue.main.async { onStateChange?() } }
    }

    /// Main-queue notification when readiness changes (drives onboarding and the menu).
    static var onStateChange: (() -> Void)?

    static var preferred: Engine {
        Engine(rawValue: Pref.string(Pref.speechEngine)) ?? (isParakeetBuiltIn ? .parakeet : .apple)
    }

    /// The engine a new recording will use right now.
    static var active: Engine {
        preferred == .parakeet && parakeetState == .ready ? .parakeet : .apple
    }

    static var isReady: Bool { active == .parakeet || AppleSpeech.isReady }

    /// Audio format the active engine wants from the microphone.
    static var audioFormat: AVAudioFormat? {
        active == .parakeet ? parakeetFormat : AppleSpeech.audioFormat
    }

    static let parakeetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Set once the user agrees to the one-time model download (onboarding or Settings).
    static var parakeetApproved: Bool {
        get { UserDefaults.standard.bool(forKey: "parakeetApproved") }
        set { UserDefaults.standard.set(newValue, forKey: "parakeetApproved") }
    }

    /// Gets Apple's engine ready immediately, then Parakeet in the background if it's approved.
    static func prepare(progress: ((String) -> Void)? = nil) async throws {
        try await AppleSpeech.prepare(progress: progress)
        if preferred == .parakeet, parakeetApproved { Task.detached { await prepareParakeet() } }
    }

    /// User-initiated download (onboarding's "Download" button, Settings).
    static func downloadParakeet() {
        parakeetApproved = true
        Task.detached { await prepareParakeet() }
    }

    static func prepareParakeet() async {
        #if canImport(FluidAudio)
        guard parakeetState != .ready, parakeetState != .downloading else { return }
        parakeetState = .downloading
        do {
            try await ParakeetEngine.shared.prepare()
            parakeetState = .ready
        } catch {
            debugLog("parakeet: \(error)")
            parakeetState = .failed(error.localizedDescription)
        }
        #endif
    }

    static func makeSession() -> DictationSession {
        #if canImport(FluidAudio)
        if active == .parakeet { return ParakeetSession() }
        #endif
        return AppleLiveSession()
    }

    /// Dev/test path: transcribe an audio file with the active engine.
    static func transcribe(file url: URL) async throws -> String {
        #if canImport(FluidAudio)
        if active == .parakeet { return try await ParakeetEngine.shared.transcribe(file: url) }
        #endif
        return try await AppleSpeech.transcribe(file: url)
    }

    static var engineName: String {
        active == .parakeet ? "Parakeet (\(Pref.string(Pref.parakeetModel)))" : "Apple SpeechAnalyzer"
    }
}
