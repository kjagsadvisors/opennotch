import Foundation
import FoundationModels

/// Anything that turns a prompt into text. Only used when words must be *generated*
/// (cleanup, rewrites, answers, plans); decisions go through `Decider` instead.
protocol TextModel {
    var name: String { get }
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
}

enum LLMError: LocalizedError {
    case unavailable(String)
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unavailable(let s): return s
        case .http(let code, let body): return "LLM HTTP \(code): \(body.prefix(200))"
        case .empty: return "The model returned no text"
        }
    }
}

enum LLMs {
    /// The model used for rewriting, answering and planning.
    static func current() -> TextModel? {
        switch Pref.string(Pref.llmProvider) {
        case "anthropic":
            if let model = claude() { return model }
        case "openai":
            return OpenAICompatibleModel(baseURL: Pref.string(Pref.openAIBaseURL), model: Pref.string(Pref.openAIModel), apiKey: Secrets.get(.openai))
        case "groq":
            if let key = Secrets.get(.groq) { return CleanupProvider.groqModel(key: key) }
        case "cerebras":
            if let key = Secrets.get(.cerebras) { return CleanupProvider.cerebrasModel(key: key) }
        default:
            break
        }
        return AppleModel.availableInstance ?? cloudFallback()
    }

    /// Claude Haiku with your own key if you've added one, otherwise through OpenNotch Pro.
    static func claude() -> AnthropicModel? {
        if let key = Secrets.get(.anthropic) { return AnthropicModel(apiKey: key, model: Pref.string(Pref.anthropicModel)) }
        if Pro.isActive, let license = Pro.licenseKey { return AnthropicModel.pro(license: license, activation: Pro.activationID) }
        return nil
    }

    /// The model for tiny, latency-sensitive jobs like pulling a search query out of a sentence.
    static func fast() -> TextModel? {
        cleanup() ?? AppleModel.availableInstance ?? current()
    }

    /// The model that cleans up dictation, or nil for the rules-only pass.
    ///
    /// Dictation cleanup needs a model that follows instructions exactly (open-source dictation
    /// apps recommend 8B+ parameters), so Apple's ~3B on-device model is opt-in only.
    static func cleanup() -> TextModel? {
        switch CleanupProvider.resolved {
        case .groq: return Secrets.get(.groq).map { CleanupProvider.groqModel(key: $0) }
        case .cerebras: return Secrets.get(.cerebras).map { CleanupProvider.cerebrasModel(key: $0) }
        case .anthropic: return LLMs.claude()
        case .openai: return OpenAICompatibleModel(baseURL: Pref.string(Pref.openAIBaseURL), model: Pref.string(Pref.openAIModel), apiKey: Secrets.get(.openai))
        case .apple: return AppleModel.availableInstance
        case .rules, .auto: return nil
        }
    }

    private static func cloudFallback() -> TextModel? {
        if let model = claude() { return model }
        if let key = Secrets.get(.groq) { return CleanupProvider.groqModel(key: key) }
        return nil
    }
}

enum CleanupProvider: String, CaseIterable, Identifiable {
    case auto, rules, groq, cerebras, anthropic, openai, apple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Automatic (Claude if you've added a key)"
        case .rules: return "Rules only (instant, offline)"
        case .groq: return "Groq · gpt-oss-20b"
        case .cerebras: return "Cerebras · gpt-oss-120b"
        case .anthropic: return "Anthropic · Claude Haiku"
        case .openai: return "Local / OpenAI-compatible (Ollama…)"
        case .apple: return "Apple on-device (not recommended)"
        }
    }

    /// What `.auto` means right now: the fastest provider you have a key for.
    static var resolved: CleanupProvider {
        let chosen = CleanupProvider(rawValue: Pref.string(Pref.cleanupProvider)) ?? .auto
        guard chosen == .auto else { return chosen }
        if Secrets.get(.anthropic) != nil || Pro.isActive { return .anthropic }
        if Secrets.get(.groq) != nil { return .groq }
        if Secrets.get(.cerebras) != nil { return .cerebras }
        return .rules
    }

    // gpt-oss is a reasoning model; low effort keeps it at a few hundred milliseconds.
    static func groqModel(key: String) -> TextModel {
        OpenAICompatibleModel(baseURL: "https://api.groq.com/openai/v1", model: "openai/gpt-oss-20b", apiKey: key,
                              extraBody: ["reasoning_effort": "low"])
    }

    static func cerebrasModel(key: String) -> TextModel {
        OpenAICompatibleModel(baseURL: "https://api.cerebras.ai/v1", model: "gpt-oss-120b", apiKey: key,
                              extraBody: ["reasoning_effort": "low"])
    }
}

struct AppleModel: TextModel {
    var name: String { "Apple on-device" }

    static var availableInstance: AppleModel? {
        SystemLanguageModel.default.isAvailable ? AppleModel() : nil
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        let r = try await session.respond(to: user, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: maxTokens))
        return r.content
    }
}

/// Claude via the Messages API (raw HTTPS; there is no official Swift SDK), either directly with
/// the user's key or through the OpenNotch Pro proxy with their license key.
struct AnthropicModel: TextModel {
    let apiKey: String
    let model: String
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Set for Pro: the license's device activation, checked by the proxy.
    var proActivation: String?
    var viaPro = false

    var name: String { viaPro ? "\(model) (OpenNotch Pro)" : model }

    static func pro(license: String, activation: String?) -> AnthropicModel {
        AnthropicModel(apiKey: license, model: "claude-haiku-4-5", endpoint: ProConfig.proxyEndpoint, proActivation: activation, viaPro: true)
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        var req = URLRequest(url: endpoint, timeoutInterval: 30)
        req.httpMethod = "POST"
        if viaPro {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            if let proActivation, !proActivation.isEmpty { req.setValue(proActivation, forHTTPHeaderField: "X-OpenNotch-Activation") }
        } else {
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]]
        else { throw LLMError.empty }
        if !viaPro, let usage = obj["usage"] as? [String: Any] {
            UsageMeter.addAnthropic(input: usage["input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0)
        }
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw LLMError.empty }
        return text
    }
}

/// Any OpenAI-compatible chat endpoint: Groq, Cerebras, OpenRouter, or Ollama / LM Studio locally.
struct OpenAICompatibleModel: TextModel {
    let baseURL: String
    let model: String
    let apiKey: String?
    var extraBody: [String: Any] = [:]

    var name: String { model }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: base + "/chat/completions") else { throw LLMError.unavailable("Bad base URL") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": 0.2,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        body.merge(extraBody) { _, new in new }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let raw = message["content"] as? String
        else { throw LLMError.empty }
        let text = stripReasoning(raw)
        guard !text.isEmpty else { throw LLMError.empty }
        return text
    }
}

/// Some local reasoning models put their thinking inline; keep only the answer.
func stripReasoning(_ text: String) -> String {
    text.replacing(#/(?s)<think>.*?</think>/#, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
}

struct TimeoutError: Error {}

/// Set OPENNOTCH_DEBUG=1 to see why a model step fell back.
func debugLog(_ message: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["OPENNOTCH_DEBUG"] != nil { print("[debug] \(message())") }
}

func withTimeout<T>(_ seconds: Double, _ op: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

/// Pulls the first JSON object out of a model reply (models sometimes wrap it in prose or fences).
func extractJSONObject(_ text: String) -> [String: Any]? {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
    let slice = String(text[start...end])
    return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
}
