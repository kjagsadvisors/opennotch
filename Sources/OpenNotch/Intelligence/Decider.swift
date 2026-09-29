import Foundation

/// A typed question in the shape Jev's System One API uses: every decision in OpenNotch
/// (which intent, which app, which button, is this risky) is one of these instead of an LLM prompt.
struct Question {
    enum Kind {
        /// Pick one key. Values are the descriptions the model reads.
        case choice([(key: String, description: String)])
        /// Yes/no, answered as a probability of "true".
        case noul(whenTrue: String?, whenFalse: String?)
    }

    let instructions: String
    let kind: Kind

    static func choice(_ instructions: String, _ options: [(key: String, description: String)]) -> Question {
        Question(instructions: instructions, kind: .choice(options))
    }

    static func yesNo(_ instructions: String, whenTrue: String? = nil, whenFalse: String? = nil) -> Question {
        Question(instructions: instructions, kind: .noul(whenTrue: whenTrue, whenFalse: whenFalse))
    }
}

struct Answer {
    /// Chosen key for `.choice` questions.
    var choice: String?
    /// Probability of "true" for `.noul` questions.
    var probability: Double?
    /// Calibrated confidence in `choice` (Jev) or a fixed prior (local backend).
    var confidence: Double
}

protocol Decider {
    var name: String { get }
    /// True when asking many questions in one call is cheap (Jev answers them in parallel).
    var batchesWell: Bool { get }
    /// Most options a single choice question can carry.
    var maxChoices: Int { get }
    func evaluate(state: String, questions: [String: Question]) async throws -> [String: Answer]
}

enum DeciderError: LocalizedError {
    case unavailable(String)
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let s): return s
        case .http(let code, let body): return "Decider HTTP \(code): \(body.prefix(200))"
        case .badResponse(let s): return "Decider returned an unexpected response: \(s)"
        }
    }
}

enum Deciders {
    /// Jev through whichever door is open: your Vercel AI Gateway key, a TypeSafe key, or Pro.
    static func jev() -> JevDecider? {
        if let key = Secrets.get(.aiGateway) {
            return JevDecider(apiKey: key, endpoint: JevDecider.gatewayEndpoint, model: "typesafe-ai/jev", label: "Jev (AI Gateway)")
        }
        if let key = Secrets.get(.jev) {
            return JevDecider(apiKey: key, endpoint: Pref.string(Pref.jevEndpoint), model: Pref.string(Pref.jevModel), label: "Jev (TypeSafe)")
        }
        if Pro.isActive, let license = Pro.licenseKey {
            var headers: [String: String] = [:]
            if let activation = Pro.activationID, !activation.isEmpty { headers["X-OpenNotch-Activation"] = activation }
            return JevDecider(apiKey: license, endpoint: JevDecider.proEndpoint, model: "typesafe-ai/jev", extraHeaders: headers, label: "Jev (OpenNotch Pro)")
        }
        return nil
    }

    /// Automatic: Jev first (fastest, calibrated), then Claude, then on-device.
    static func current() -> Decider {
        let backend = Pref.string(Pref.deciderBackend)
        let jevDecider: Decider? = jev()
        let claude: Decider? = LLMs.claude().map { ClaudeDecider(claude: $0) }
        let local: Decider = LocalDecider()
        switch backend {
        case "claude": return claude ?? local
        case "local": return local
        default: return jevDecider ?? claude ?? local
        }
    }

    /// Cheap enough to call on every partial transcript (speculative routing).
    static var isCheap: Bool { jev() != nil }
}

/// Keeps option lists under a backend's limit by ranking them against what the user said.
enum OptionRanker {
    static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 })
    }

    static func top<T>(_ items: [T], label: (T) -> String, query: String, limit: Int) -> [T] {
        guard items.count > limit else { return items }
        let q = tokens(query)
        let lowered = query.lowercased()
        let scored = items.enumerated().map { (i, item) -> (Int, Double, T) in
            let l = label(item).lowercased()
            var score = Double(tokens(l).intersection(q).count) * 2
            if !l.isEmpty && lowered.contains(l) { score += 3 }
            for t in q where l.contains(t) { score += 0.5 }
            return (i, score, item)
        }
        // Keep original order among ties so on-screen order still means something.
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(limit).map { $0.2 }
    }
}
