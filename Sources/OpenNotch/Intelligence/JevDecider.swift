import Foundation

/// TypeSafe's Jev System One model: typed, calibrated decisions in one parallel pass.
/// API reference: https://docs.typesafe.ai/api. The same request shape works three ways:
/// TypeSafe directly, Vercel AI Gateway's TypeSafe-compatible API, or the OpenNotch Pro proxy.
struct JevDecider: Decider {
    let apiKey: String
    let endpoint: String
    let model: String
    var extraHeaders: [String: String] = [:]
    var label = "Jev"

    static let typesafeEndpoint = "https://api.typesafe.ai/v1/systemone"
    static let gatewayEndpoint = "https://ai-gateway.vercel.sh/typesafe/v1/systemone"
    static let proEndpoint = "https://opennotch.ai/api/v1/decide"

    var name: String { label }
    var batchesWell: Bool { true }
    var maxChoices: Int { Self.maxChoices }

    static let maxChoices = 255

    func evaluate(state: String, questions: [String: Question]) async throws -> [String: Answer] {
        guard !apiKey.isEmpty else { throw DeciderError.unavailable("No Jev API key set") }
        guard let url = URL(string: endpoint) else { throw DeciderError.unavailable("Bad Jev endpoint") }

        var qs: [String: Any] = [:]
        for (id, q) in questions {
            switch q.kind {
            case .choice(let options):
                var criteria: [String: String] = [:]
                for o in options.prefix(Self.maxChoices) { criteria[o.key] = o.description }
                qs[id] = ["type": "choice", "instructions": q.instructions, "criteria": criteria]
            case .noul(let t, let f):
                var body: [String: Any] = ["type": "noul", "instructions": q.instructions]
                var criteria: [String: String] = [:]
                if let t { criteria["true"] = t }
                if let f { criteria["false"] = f }
                if !criteria.isEmpty { body["criteria"] = criteria }
                qs[id] = body
            }
        }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["state": state, "model": model, "questions": qs])

        var attempt = 0
        while true {
            let data: Data, resp: URLResponse
            do {
                (data, resp) = try await URLSession.shared.data(for: req)
            } catch let error as URLError where error.code == .timedOut && attempt == 0 {
                attempt += 1  // one retry: gateway cold starts occasionally stall
                continue
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (code == 429 || code == 529) && attempt < 2 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(250_000_000 * attempt))
                continue
            }
            guard code == 200 else { throw DeciderError.http(code, String(data: data, encoding: .utf8) ?? "") }
            return try parse(data)
        }
    }

    private func parse(_ data: Data) throws -> [String: Answer] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = obj["answers"] as? [String: [String: Any]]
        else { throw DeciderError.badResponse(String(data: data, encoding: .utf8) ?? "") }

        if let usage = obj["usage"] as? [String: Any], let input = usage["input_tokens"] as? Int {
            UsageMeter.addJev(inputTokens: input)
        }

        var out: [String: Answer] = [:]
        for (id, a) in answers {
            if let p = (a["noul"] as? NSNumber)?.doubleValue {
                out[id] = Answer(choice: nil, probability: p, confidence: max(p, 1 - p))
            } else {
                let choice = a["choice"] as? String
                let conf = (a["confidence"] as? NSNumber)?.doubleValue
                    ?? ((a["probabilities"] as? [String: NSNumber])?[choice ?? ""]?.doubleValue ?? 0)
                out[id] = Answer(choice: choice, probability: nil, confidence: conf)
            }
        }
        return out
    }
}
