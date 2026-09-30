import AppKit
import Foundation

/// A resolved command, ready to show (and confirm, if needed) before it runs.
struct PlannedAction {
    let summary: String
    let detail: String?
    let icon: String
    let confidence: Double
    let risky: Bool
    /// Returns an optional message to show afterwards (e.g. an answer).
    let run: () async throws -> String?
    /// Cheap, reversible head start taken while the user is still talking (e.g. launch the app hidden).
    var prewarm: (() -> Void)? = nil
    /// Easy to undo (opening an app, a search, a web page), so only a real guess stops to ask.
    var harmless = false

    var needsConfirmation: Bool {
        if risky { return true }
        return confidence < (harmless ? 0.3 : Pref.double(Pref.autoRunConfidence))
    }

    func markedHarmless() -> PlannedAction {
        var copy = self
        copy.harmless = true
        return copy
    }
}

enum RouteResult {
    case action(PlannedAction)
    case unsure(String)
}

/// Turns a spoken command into an action.
///
/// Speed/cost design: every *decision* (intent, target app, which button, risky or not) is a typed
/// question for a System One model (Jev), asked in a single parallel call. Words are only
/// *generated* by an LLM when the task truly needs them (rewrites, answers, multi-step plans).
final class Router {
    let decider: Decider
    let apps: AppIndex
    /// Timing for the last route, for the dev CLI.
    private(set) var lastDecisionMs: Double = 0

    init(decider: Decider = Deciders.current(), apps: AppIndex = .shared) {
        self.decider = decider
        self.apps = apps
    }

    /// One slot is reserved for "none".
    private var choiceLimit: Int { decider.maxChoices - 1 }

    static let riskyQuestion = Question.yesNo(
        "Would carrying out this command send or post a message, delete or overwrite data, spend money, submit a form, or otherwise do something hard to undo?",
        whenTrue: "Consequential or hard to undo", whenFalse: "Safe, easily undone, or read-only"
    )

    func route(_ said: String, context: ScreenContext) async throws -> RouteResult {
        let state = Self.state(said, context)
        var questions: [String: Question] = ["intent": Intent.question, "risky": Self.riskyQuestion]
        if decider.batchesWell {
            // Jev answers all of these in one pass for a fraction of a cent, so ask every
            // target question up front and skip a second round-trip.
            for (id, q) in targetQuestions(Intent.allCases, said: said, context: context) { questions[id] = q }
        }

        let t0 = Date()
        var answers = try await decider.evaluate(state: state, questions: questions)

        guard let intentKey = answers["intent"]?.choice, let intent = Intent(rawValue: intentKey) else {
            return .unsure("I didn't catch a command.")
        }
        if !decider.batchesWell {
            let more = targetQuestions([intent], said: said, context: context)
            if !more.isEmpty {
                for (k, v) in try await decider.evaluate(state: state, questions: more) { answers[k] = v }
            }
        }
        lastDecisionMs = Date().timeIntervalSince(t0) * 1000

        let intentConf = answers["intent"]?.confidence ?? 0
        let risky = (answers["risky"]?.probability ?? 0) > 0.5
        return try await plan(intent, confidence: intentConf, risky: risky, answers: answers, said: said, context: context)
    }

    static func state(_ said: String, _ context: ScreenContext) -> String {
        var s = "User said: \"\(said)\"\nFrontmost app: \(context.appName)"
        if let w = context.windowTitle { s += "\nWindow title: \(w)" }
        s += "\nText is selected: \(context.hasSelection ? "yes" : "no")"
        return s
    }

    private func targetQuestions(_ intents: [Intent], said: String, context: ScreenContext) -> [String: Question] {
        var q: [String: Question] = [:]
        let wanted = Set(intents)
        if wanted.contains(.openApp), !apps.apps.isEmpty {
            q["app"] = apps.question(for: said, limit: choiceLimit)
        }
        if wanted.contains(.shortcut) { q["shortcut"] = Shortcut.question }
        if wanted.contains(.system) { q["system"] = SystemAction.question }
        if wanted.contains(.click) || (decider.batchesWell && wanted.contains(.menu)), !context.elements.isEmpty {
            q["element"] = elementQuestion(context.elements, said: said)
        }
        if wanted.contains(.menu) || (decider.batchesWell && (wanted.contains(.click) || wanted.contains(.shortcut))), !context.menuItems.isEmpty {
            q["menu"] = menuQuestion(context.menuItems, said: said)
        }
        return q
    }

    private func elementQuestion(_ els: [UITarget], said: String) -> Question {
        let top = OptionRanker.top(els, label: \.label, query: said, limit: choiceLimit)
        return .choice("Which on-screen control should be clicked or focused to do what the user said? Pick none if nothing matches.",
                       top.map { ($0.label, $0.label) } + [("none", "Nothing on screen matches")])
    }

    private func menuQuestion(_ items: [UITarget], said: String) -> Question {
        let top = OptionRanker.top(items, label: \.label, query: said, limit: choiceLimit)
        return .choice("Which menu command does what the user said? Pick none if nothing matches.",
                       top.map { ($0.label, $0.label) } + [("none", "No menu command matches")])
    }

    // MARK: - Planning

    private func plan(_ intent: Intent, confidence: Double, risky: Bool, answers: [String: Answer], said: String, context: ScreenContext) async throws -> RouteResult {
        func pick(_ id: String) -> (String, Double)? {
            guard let a = answers[id], let c = a.choice, c != "none" else { return nil }
            return (c, a.confidence)
        }

        let result = try await planPrimary(intent, confidence: confidence, risky: risky, answers: answers, said: said, context: context, pick: pick)
        guard case .unsure = result, decider.batchesWell else { return result }

        // The chosen intent had no matching target, but the same batched call also scored every other
        // target list. Use the most confident alternative (e.g. "full screen" is a shortcut and a menu
        // item, not a system setting).
        let alternatives: [(Intent, String)] = [(.shortcut, "shortcut"), (.menu, "menu"), (.click, "element"), (.system, "system"), (.openApp, "app")]
        let best = alternatives
            .filter { $0.0 != intent }
            .compactMap { alt -> (Intent, Double)? in pick(alt.1).map { (alt.0, $0.1) } }
            .filter { $0.1 >= 0.6 }
            .max { $0.1 < $1.1 }
        guard let (fallbackIntent, fallbackConfidence) = best else { return result }
        debugLog("fallback \(intent.rawValue) → \(fallbackIntent.rawValue) (\(fallbackConfidence))")
        // A fallback is a second guess, so it always asks first.
        let fallback = try await planPrimary(fallbackIntent, confidence: min(confidence, fallbackConfidence, 0.7), risky: risky,
                                             answers: answers, said: said, context: context, pick: pick)
        return fallback
    }

    private func planPrimary(_ intent: Intent, confidence: Double, risky: Bool, answers: [String: Answer], said: String,
                             context: ScreenContext, pick: (String) -> (String, Double)?) async throws -> RouteResult {
        switch intent {
        case .openApp:
            guard let (name, conf) = pick("app") else { return .unsure("I couldn't find that app.") }
            var action = PlannedAction(summary: "Open \(name)", detail: nil, icon: "app.badge", confidence: min(confidence, conf), risky: false) { [apps] in
                try await apps.open(name)
                return nil
            }
            action.prewarm = { [apps] in apps.prelaunch(name) }
            action.harmless = true
            return .action(action)

        case .click, .menu:
            let order = intent == .click ? ["element", "menu"] : ["menu", "element"]
            for id in order {
                guard let (label, conf) = pick(id) else { continue }
                let pool = id == "element" ? context.elements : context.menuItems
                guard let target = pool.first(where: { $0.label == label }) else { continue }
                let verb = id == "menu" ? "Choose" : (target.kind == .focus ? "Focus" : "Click")
                return .action(PlannedAction(
                    summary: "\(verb) \(label)", detail: "in \(context.appName)", icon: id == "menu" ? "filemenu.and.selection" : "cursorarrow.click",
                    confidence: min(confidence, conf), risky: risky || Self.soundsRisky(label)
                ) {
                    guard AX.perform(target) else { throw NSError(domain: "OpenNotch", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(context.appName) didn't respond to the click"]) }
                    return nil
                })
            }
            return .unsure(context.elements.isEmpty && context.menuItems.isEmpty
                           ? "I can't see \(context.appName)'s controls. Is Accessibility enabled for OpenNotch?"
                           : "I couldn't find that on screen.")

        case .shortcut:
            if let (id, conf) = pick("shortcut"), let sc = Shortcut.find(id) {
                return .action(PlannedAction(summary: sc.description, detail: nil, icon: "command", confidence: min(confidence, conf),
                                             risky: risky || id == "quit_app") {
                    sc.run()
                    return nil
                })
            }
            if let (label, conf) = pick("menu"), let target = context.menuItems.first(where: { $0.label == label }) {
                return .action(PlannedAction(summary: "Choose \(label)", detail: nil, icon: "filemenu.and.selection",
                                             confidence: min(confidence, conf), risky: risky || Self.soundsRisky(label)) {
                    AX.perform(target)
                    return nil
                })
            }
            return .unsure("I don't know that shortcut.")

        case .system:
            guard let (id, conf) = pick("system"), let action = SystemAction(rawValue: id) else { return .unsure("I don't know that setting.") }
            return .action(PlannedAction(summary: action.summary, detail: nil, icon: "gearshape", confidence: min(confidence, conf), risky: false) {
                try action.run()
                return nil
            })

        case .type:
            let text = await Extract.textToType(said)
            return .action(PlannedAction(summary: "Type “\(text.prefix(60))”", detail: nil, icon: "keyboard", confidence: confidence, risky: false) {
                TextInserter.insert(text)
                return nil
            })

        case .dictation:
            return .action(PlannedAction(summary: "Insert text", detail: nil, icon: "text.cursor", confidence: confidence, risky: false) {
                TextInserter.insert(await Polisher.polish(said, appName: context.appName))
                return nil
            })

        case .searchWeb:
            let query = await Extract.searchQuery(said)
            return .action(PlannedAction(summary: "Search “\(query)”", detail: nil, icon: "magnifyingglass", confidence: confidence, risky: false) {
                Executors.search(query)
                return nil
            }.markedHarmless())

        case .openURL:
            guard let url = await Extract.url(said) else {
                let query = await Extract.searchQuery(said)
                return .action(PlannedAction(summary: "Search “\(query)”", detail: nil, icon: "magnifyingglass", confidence: confidence, risky: false) {
                    Executors.search(query)
                    return nil
                }.markedHarmless())
            }
            return .action(PlannedAction(summary: "Go to \(url.host ?? url.absoluteString)", detail: nil, icon: "safari", confidence: confidence, risky: false) {
                NSWorkspace.shared.open(url)
                return nil
            }.markedHarmless())

        case .rewrite:
            guard context.hasSelection else { return .unsure("Select some text first, then ask me to change it.") }
            return .action(PlannedAction(summary: "Rewrite selection", detail: said, icon: "wand.and.stars", confidence: confidence, risky: false) {
                try await Executors.rewriteSelection(instruction: said)
                return nil
            })

        case .ask:
            return .action(PlannedAction(summary: "Answer", detail: nil, icon: "sparkle", confidence: 1, risky: false) {
                try await Executors.answer(said, context: context)
            })

        case .fillForm:
            return .action(PlannedAction(summary: "Fill the form from your clipboard", detail: nil, icon: "doc.on.clipboard", confidence: confidence, risky: false) {
                try await FormFiller.fill(app: context.app, instruction: said)
            })

        case .multiStep where decider.batchesWell:
            // Jev (or Claude) drives a step-by-step loop; risky steps ask first.
            return .action(PlannedAction(summary: "Working on it", detail: said, icon: "bolt.fill", confidence: confidence, risky: false) { [decider] in
                let outcome = try await AgentLoop(goal: said, decider: decider).run()
                return outcome.summary
            })

        case .multiStep:
            let steps = try await MultiStep.plan(said, context: context)
            guard !steps.isEmpty else { return .unsure("I can't do that one yet.") }
            let listing = steps.enumerated().map { "\($0.offset + 1). \($0.element.summary)" }.joined(separator: "\n")
            // Multi-step plans always get a confirmation card: they touch several apps.
            return .action(PlannedAction(summary: "Run \(steps.count) steps", detail: listing, icon: "list.number", confidence: 0, risky: true) { [self] in
                try await MultiStep.run(steps, router: self)
                return nil
            })
        }
    }

    static func soundsRisky(_ label: String) -> Bool {
        let l = label.lowercased()
        return ["send", "delete", "remove", "trash", "erase", "buy", "purchase", "pay", "order", "submit", "post", "publish",
                "reply all", "empty", "log out", "sign out", "shut down", "restart", "quit", "discard", "merge", "deploy", "unsubscribe"]
            .contains { l.contains($0) }
    }

    // MARK: - Single-target resolution (used by multi-step plans)

    func resolveApp(_ text: String) async throws -> String? {
        if let exact = apps.apps.keys.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) { return exact }
        let a = try await decider.evaluate(state: "User wants the app: \(text)", questions: ["app": apps.question(for: text, limit: choiceLimit)])
        return a["app"]?.choice
    }

    func resolveShortcut(_ text: String) async throws -> Shortcut? {
        let a = try await decider.evaluate(state: "Keyboard action wanted: \(text)", questions: ["s": Shortcut.question])
        return a["s"]?.choice.flatMap(Shortcut.find)
    }

    func resolveTarget(_ text: String, menu: Bool) async throws -> UITarget? {
        let ctx = ScreenContext.capture(app: NSWorkspace.shared.frontmostApplication)
        let pool = menu ? ctx.menuItems : ctx.elements
        guard !pool.isEmpty else { return nil }
        let q = menu ? menuQuestion(pool, said: text) : elementQuestion(pool, said: text)
        let a = try await decider.evaluate(state: Self.state(text, ctx), questions: ["t": q])
        guard let label = a["t"]?.choice, label != "none" else { return nil }
        return pool.first { $0.label == label }
    }
}

/// Pulls the free-text argument out of a command. Cheap regexes first; a model only when needed.
enum Extract {
    static func textToType(_ said: String) async -> String {
        if let m = said.firstMatch(of: #/(?i)^\s*(?:please\s+)?(?:type|write|enter|input)(?:\s+out)?[:,]?\s+(.+)$/#) {
            return String(m.1)
        }
        return await ask("Return only the exact text the user wants typed, nothing else.", said) ?? said
    }

    static func searchQuery(_ said: String) async -> String {
        if let m = said.firstMatch(of: #/(?i)^\s*(?:please\s+)?(?:search(?:\s+the\s+web|\s+google|\s+online)?(?:\s+for)?|google|look\s+up|find\s+out)\s+(.+?)[.?!]?$/#) {
            return String(m.1)
        }
        return await ask("Return only the web search query for this request, nothing else.", said) ?? said
    }

    static func url(_ said: String) async -> URL? {
        let spoken = said.lowercased().replacingOccurrences(of: " dot ", with: ".")
        if let m = spoken.firstMatch(of: #/((?:https?:\/\/)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?:\/[^\s]*)?)/#) {
            var s = String(m.1).trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            if !s.hasPrefix("http") { s = "https://" + s }
            return URL(string: s)
        }
        guard let out = await ask("Return only the full https URL of the website the user wants, or NONE if unsure.", said),
              out.uppercased() != "NONE", let url = URL(string: out.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true
        else { return nil }
        return url
    }

    private static func ask(_ system: String, _ said: String) async -> String? {
        guard let model = LLMs.fast() else { return nil }
        let prompt = system + " Copy words from the request; never answer it or add words of your own."
        let out = try? await withTimeout(4) { try await model.complete(system: prompt, user: "Request: \(said)", maxTokens: 200) }
        guard let text = out?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”"))).nilIfEmpty else { return nil }
        // An extraction reuses the speaker's words. If most words are new, the model answered instead.
        let said = OptionRanker.tokens(said), got = OptionRanker.tokens(text)
        guard !got.isEmpty, Double(got.intersection(said).count) / Double(got.count) >= 0.6 else {
            debugLog("extraction rejected: \(text)")
            return nil
        }
        return text
    }
}

enum Executors {
    static func search(_ query: String) {
        let template = Pref.string(Pref.searchURL)
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: template.replacingOccurrences(of: "%s", with: encoded)) { NSWorkspace.shared.open(url) }
    }

    static func answer(_ question: String, context: ScreenContext) async throws -> String {
        guard let model = LLMs.current() else { throw LLMError.unavailable("No language model available. Turn on Apple Intelligence or add an API key.") }
        return try await model.complete(
            system: "You are a voice assistant on the user's Mac. Answer in at most three short sentences of plain text, no markdown.",
            user: "(Frontmost app: \(context.appName))\n\(question)", maxTokens: 300
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rewriteSelection(instruction: String) async throws {
        guard let model = LLMs.current() else { throw LLMError.unavailable("No language model available.") }
        guard let selected = AX.selectedText(), !selected.isEmpty else {
            throw NSError(domain: "OpenNotch", code: 4, userInfo: [NSLocalizedDescriptionKey: "Couldn't read the selected text"])
        }
        let out = try await model.complete(
            system: "Rewrite the user's text according to their instruction. Output only the rewritten text, with no preamble or quotes.",
            user: "Instruction: \(instruction)\n\nText:\n\(selected)", maxTokens: max(256, selected.count)
        )
        TextInserter.insert(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Multi-app tasks: an LLM writes a short plan in a fixed vocabulary, then each step's target
/// is resolved with the same typed decisions single commands use.
enum MultiStep {
    struct Step {
        let type: String
        let target: String

        var summary: String {
            switch type {
            case "open_app": return "Open \(target)"
            case "open_url": return "Go to \(target)"
            case "search_web": return "Search “\(target)”"
            case "type": return "Type “\(target.prefix(40))”"
            case "shortcut": return target.capitalized
            case "click": return "Click \(target)"
            case "menu": return "Choose \(target)"
            case "wait": return "Wait \(target)s"
            default: return "\(type) \(target)"
            }
        }
    }

    static let allowed: Set<String> = ["open_app", "open_url", "search_web", "type", "shortcut", "click", "menu", "wait"]

    static func plan(_ said: String, context: ScreenContext) async throws -> [Step] {
        guard let model = LLMs.current() else { throw LLMError.unavailable("Multi-step tasks need a language model. Turn on Apple Intelligence or add an API key.") }
        let system = """
        You turn a spoken request into a short list of steps that a Mac automation will run. Step types:
        - open_app: target = application name
        - open_url: target = full https URL
        - search_web: target = search query
        - type: target = exact text to type at the cursor
        - shortcut: target = keyboard action in plain words (e.g. "new tab", "press return", "select all")
        - click: target = the button or link to click in the frontmost app, in plain words
        - menu: target = the menu command in plain words
        - wait: target = seconds
        Reply with JSON only: {"steps":[{"type":"...","target":"..."}]}. Use at most 8 steps and only these types.
        If the request can't be done with these steps, reply {"steps":[]}.
        """
        let out = try await model.complete(system: system, user: "Frontmost app: \(context.appName)\nRequest: \(said)", maxTokens: 600)
        guard let obj = extractJSONObject(out), let raw = obj["steps"] as? [[String: Any]] else { return [] }
        return raw.compactMap { s in
            guard let type = s["type"] as? String, allowed.contains(type) else { return nil }
            let target = (s["target"] as? String) ?? (s["target"] as? NSNumber)?.stringValue ?? ""
            return Step(type: type, target: target)
        }.prefix(8).map { $0 }
    }

    static func run(_ steps: [Step], router: Router) async throws {
        for step in steps {
            switch step.type {
            case "open_app":
                guard let name = try await router.resolveApp(step.target) else { throw err("Couldn't find the app \(step.target)") }
                try await router.apps.open(name)
                try await pause(1.2)
            case "open_url":
                if let url = URL(string: step.target.hasPrefix("http") ? step.target : "https://" + step.target) { NSWorkspace.shared.open(url) }
                try await pause(1.2)
            case "search_web":
                Executors.search(step.target)
                try await pause(1.2)
            case "type":
                TextInserter.insert(step.target)
                try await pause(0.4)
            case "shortcut":
                guard let sc = try await router.resolveShortcut(step.target) else { throw err("Unknown keyboard action: \(step.target)") }
                sc.run()
                try await pause(0.4)
            case "click", "menu":
                guard let t = try await router.resolveTarget(step.target, menu: step.type == "menu") else { throw err("Couldn't find “\(step.target)” on screen") }
                AX.perform(t)
                try await pause(0.6)
            case "wait":
                try await pause(min(10, Double(step.target) ?? 1))
            default:
                break
            }
        }
    }

    private static func pause(_ s: Double) async throws { try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    private static func err(_ s: String) -> Error { NSError(domain: "OpenNotch", code: 5, userInfo: [NSLocalizedDescriptionKey: s]) }
}
