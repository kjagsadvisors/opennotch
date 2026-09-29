import Foundation
import Security

/// Preference keys live here so SwiftUI (@AppStorage) and the engine read the same values.
enum Pref {
    static let dictationKey = "dictationKey"
    static let commandKey = "commandKey"
    static let polishEnabled = "polishEnabled"
    static let deciderBackend = "deciderBackend"      // auto | jev | local
    static let jevEndpoint = "jevEndpoint"
    static let jevModel = "jevModel"
    static let llmProvider = "llmProvider"            // apple | anthropic | openai
    static let anthropicModel = "anthropicModel"
    static let openAIBaseURL = "openAIBaseURL"
    static let openAIModel = "openAIModel"
    static let vocabulary = "vocabulary"
    static let autoRunConfidence = "autoRunConfidence"
    static let searchURL = "searchURL"
    static let speechEngine = "speechEngine"          // parakeet | apple
    static let parakeetModel = "parakeetModel"        // ultra | v3 | redux
    static let cleanupProvider = "cleanupProvider"    // rules | groq | cerebras | anthropic | openai | apple

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            dictationKey: TriggerKey.fn.rawValue,
            commandKey: TriggerKey.rightOption.rawValue,
            polishEnabled: true,
            deciderBackend: "auto",
            jevEndpoint: "https://api.typesafe.ai/v1/systemone",
            jevModel: "jev-latest",
            llmProvider: "anthropic",
            anthropicModel: "claude-haiku-4-5",
            openAIBaseURL: "http://localhost:11434/v1",
            openAIModel: "llama3.2",
            vocabulary: "",
            autoRunConfidence: 0.8,
            searchURL: "https://www.google.com/search?q=%s",
            parakeetModel: "ultra",
            cleanupProvider: "auto",
        ])
    }

    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func double(_ key: String) -> Double { UserDefaults.standard.double(forKey: key) }

    static var vocabularyList: [String] {
        string(vocabulary)
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// API keys. Environment variables win so the dev CLI works without touching the Keychain.
enum Secrets {
    enum Name: String, CaseIterable {
        case jev, aiGateway, anthropic, openai, groq, cerebras, proLicense, proActivation

        var envVars: [String] {
            switch self {
            case .jev: return ["TYPESAFE_API_KEY", "JEV_API_KEY"]
            case .aiGateway: return ["AI_GATEWAY_API_KEY"]
            case .anthropic: return ["ANTHROPIC_API_KEY"]
            case .openai: return ["OPENAI_API_KEY"]
            case .groq: return ["GROQ_API_KEY"]
            case .cerebras: return ["CEREBRAS_API_KEY"]
            case .proLicense: return ["OPENNOTCH_LICENSE_KEY"]
            case .proActivation: return []
            }
        }
    }

    private static let service = "app.opennotch.OpenNotch"

    static func get(_ name: Name) -> String? {
        for v in name.envVars {
            if let value = ProcessInfo.processInfo.environment[v], !value.isEmpty { return value }
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    static func set(_ name: Name, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Running tally of paid-API usage so the cost story is visible in the menu bar.
enum UsageMeter {
    // USD per million tokens.
    static let jevInputPrice = 0.042
    static let haikuInputPrice = 1.0
    static let haikuOutputPrice = 5.0

    private static let d = UserDefaults.standard

    static func addJev(inputTokens: Int) {
        d.set(d.integer(forKey: "usage.jev.in") + inputTokens, forKey: "usage.jev.in")
        d.set(d.integer(forKey: "usage.jev.calls") + 1, forKey: "usage.jev.calls")
    }

    static func addAnthropic(input: Int, output: Int) {
        d.set(d.integer(forKey: "usage.anthropic.in") + input, forKey: "usage.anthropic.in")
        d.set(d.integer(forKey: "usage.anthropic.out") + output, forKey: "usage.anthropic.out")
    }

    static var jevCalls: Int { d.integer(forKey: "usage.jev.calls") }

    static var estimatedDollars: Double {
        let jev = Double(d.integer(forKey: "usage.jev.in")) / 1e6 * jevInputPrice
        let claude = Double(d.integer(forKey: "usage.anthropic.in")) / 1e6 * haikuInputPrice
            + Double(d.integer(forKey: "usage.anthropic.out")) / 1e6 * haikuOutputPrice
        return jev + claude
    }

    static func reset() {
        for k in ["usage.jev.in", "usage.jev.calls", "usage.anthropic.in", "usage.anthropic.out"] { d.removeObject(forKey: k) }
    }
}
