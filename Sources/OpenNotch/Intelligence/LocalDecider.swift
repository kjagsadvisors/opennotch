import Foundation
import FoundationModels

/// Zero-cost fallback that answers the same typed questions with Apple's on-device model,
/// constrained by guided generation so it can only return a valid option.
/// Not calibrated like Jev, so confidences are a fixed prior.
struct LocalDecider: Decider {
    var name: String { "Apple on-device" }
    var batchesWell: Bool { false }
    var maxChoices: Int { Self.maxChoices }

    /// The on-device context window is small; keep option lists short.
    static let maxChoices = 60
    static let prior = 0.8

    func evaluate(state: String, questions: [String: Question]) async throws -> [String: Answer] {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw DeciderError.unavailable("Apple Intelligence is off or unavailable (\(model.availability)). Add a Jev key in Settings.")
        }
        var out: [String: Answer] = [:]
        for (id, q) in questions {
            out[id] = try await answer(q, state: state)
        }
        return out
    }

    private func answer(_ q: Question, state: String) async throws -> Answer {
        // The model picks short ids ("o3"); labels with quotes or symbols can break guided decoding.
        var keys: [String] = []
        var idToKey: [String: String] = [:]
        var listing = ""
        switch q.kind {
        case .choice(let options):
            let trimmed = options.prefix(Self.maxChoices)
            // Simple identifiers ("open_app") are easier for a small model than numbered ids.
            let readable = trimmed.allSatisfy { $0.key.wholeMatch(of: #/[a-z0-9_]{1,40}/#) != nil }
            for (i, o) in trimmed.enumerated() {
                let id = readable ? o.key : "o\(i + 1)"
                keys.append(id)
                idToKey[id] = o.key
                let desc = o.description == o.key ? o.key : "\(o.key) (\(o.description))"
                listing += "- \(id): \(desc)\n"
            }
        case .noul(let t, let f):
            keys = ["yes", "no"]
            listing = "- yes\(t.map { ": \($0)" } ?? "")\n- no\(f.map { ": \($0)" } ?? "")"
        }

        let schema = try GenerationSchema(
            root: DynamicGenerationSchema(name: "Decision", properties: [
                .init(name: "answer", schema: DynamicGenerationSchema(name: "Option", anyOf: keys))
            ]),
            dependencies: []
        )
        let session = LanguageModelSession(instructions: "You make one decision about a user's voice command on their Mac. Answer only by picking one option.")
        let prompt = "Context:\n\(state)\n\nQuestion: \(q.instructions)\n\nOptions:\n\(listing)"
        let response = try await session.respond(
            to: prompt, schema: schema, includeSchemaInPrompt: false,
            options: GenerationOptions(sampling: .greedy)
        )
        let picked: String = try response.content.value(String.self, forProperty: "answer")

        if case .noul = q.kind {
            return Answer(choice: nil, probability: picked == "yes" ? Self.prior : 1 - Self.prior, confidence: Self.prior)
        }
        return Answer(choice: idToKey[picked] ?? picked, probability: nil, confidence: Self.prior)
    }
}
