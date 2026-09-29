import AVFoundation
import Foundation
import Speech

/// Apple's on-device streaming speech-to-text (macOS 26 SpeechAnalyzer). No download beyond a
/// system asset, so it works on first launch; the model stays resident between utterances.
enum AppleSpeech {
    private(set) static var locale = Locale(identifier: "en-US")
    private(set) static var audioFormat: AVAudioFormat?

    static var isReady: Bool { audioFormat != nil }

    /// Resolves the locale, installs the speech model if needed, and learns the audio format.
    static func prepare(progress: ((String) -> Void)? = nil) async throws {
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) { locale = l }
        let modules: [any SpeechModule] = [makeTranscriber()]
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            progress?("Downloading speech model…")
            try await request.downloadAndInstall()
        }
        audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
    }

    static func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    }

    static func context() -> AnalysisContext {
        let ctx = AnalysisContext()
        let words = Pref.vocabularyList
        if !words.isEmpty { ctx.contextualStrings[.general] = words }
        return ctx
    }

    /// Dev/test path: transcribe an audio file.
    static func transcribe(file url: URL) async throws -> String {
        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task { () -> String in
            var text = ""
            for try await r in transcriber.results where r.isFinal { text += String(r.text.characters) }
            return text
        }
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One hold-to-talk session. Audio buffers can be appended before the analyzer finishes
/// starting; the stream queues them, so nothing said right after the key press is lost.
final class AppleLiveSession: DictationSession {
    private let transcriber = AppleSpeech.makeTranscriber()
    private var analyzer: SpeechAnalyzer?
    private let input: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Error>?
    private var startTask: Task<Void, Error>?

    private var finalized = ""
    private var volatile = ""

    /// Called on the main queue with the running transcript.
    var onUpdate: ((String) -> Void)?

    init() {
        (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    }

    func start() {
        let transcriber = self.transcriber
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            for try await r in transcriber.results {
                guard let self else { return }
                let text = String(r.text.characters)
                if r.isFinal {
                    self.finalized += text
                    self.volatile = ""
                } else {
                    self.volatile = text
                }
                let running = self.finalized + self.volatile
                DispatchQueue.main.async { self.onUpdate?(running) }
            }
        }

        let input = self.input
        startTask = Task {
            try await analyzer.setContext(AppleSpeech.context())
            try await analyzer.prepareToAnalyze(in: AppleSpeech.audioFormat)
            try await analyzer.start(inputSequence: input)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// Ends the audio and waits for the final transcript.
    func finish() async -> String {
        continuation.finish()
        _ = try? await startTask?.value
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = try? await resultsTask?.value
        return (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        continuation.finish()
        resultsTask?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer?.cancelAndFinishNow() }
    }
}
