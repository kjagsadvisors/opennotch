import AppKit
import Foundation

/// Headless entry points for testing the pipeline without a microphone or hotkeys:
///
///   OpenNotch --transcribe <audio file>     on-device speech-to-text
///   OpenNotch --polish "<dictation>"         dictation cleanup
///   OpenNotch --route "<command>"            decide what a command would do (never executes it)
///   OpenNotch --say "<command>"              speak with `say`, transcribe, then route
enum DevCLI {
    static func handles(_ args: [String]) -> Bool {
        guard args.count >= 2, args[1].hasPrefix("--") else { return false }
        let flag = args[1]
        let rest = args.dropFirst(2).joined(separator: " ")
        if flag == "--preview-onboarding" { return previewOnboarding(rest) }
        guard ["--transcribe", "--polish", "--route", "--say", "--agent-step"].contains(flag) else { return false }

        Pref.registerDefaults()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                switch flag {
                case "--transcribe": try await transcribe(URL(fileURLWithPath: rest))
                case "--polish": await polish(rest)
                case "--route": try await route(rest)
                case "--say": try await say(rest)
                case "--agent-step": try await agentStep(rest)
                default: break
                }
            } catch {
                print("error: \(error.localizedDescription)")
            }
            done.signal()
        }
        // Keep the main run loop alive for async work that hops to it.
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    /// Opens one onboarding screen for design review, without hotkeys, prompts or narration:
    ///   OpenNotch --preview-onboarding permissions|keyCheck|…|done|intro-splash|intro-name|intro-greeting
    private static func previewOnboarding(_ which: String) -> Bool {
        Pref.registerDefaults()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let o = Onboarding.shared
            o.previewMode = true
            AppController.shared.recordPreviewDictation(words: 26, seconds: 9.5)
            if which.hasPrefix("intro-") {
                o.introPhase = which == "intro-name" ? .name : which == "intro-greeting" ? .greeting : .splash
                o.presentIntroForPreview()
            } else {
                o.step = Onboarding.Step.allCases.first { "\($0)" == which } ?? .permissions
                o.showWindow()
            }
        }
        app.run()
        return true
    }

    /// The CLI waits for Parakeet (the app itself starts on Apple's engine while it downloads).
    private static func prepareSpeech() async throws {
        try await AppleSpeech.prepare { print($0) }
        if Speech.preferred == .parakeet, Speech.isParakeetBuiltIn {
            print("loading Parakeet (first run downloads the model)…")
            await Speech.prepareParakeet()
        }
    }

    private static func ms(since t: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(t) * 1000) }

    private static func transcribe(_ url: URL) async throws {
        let t0 = Date()
        try await prepareSpeech()
        print("speech ready (\(ms(since: t0))): \(Speech.engineName)")
        let t1 = Date()
        let text = try await Speech.transcribe(file: url)
        print("transcript (\(ms(since: t1))): \(text)")
    }

    private static func polish(_ text: String) async {
        let t0 = Date()
        print("rules: \(Polisher.basicCleanup(text)) · needs model: \(Polisher.needsModel(text)) (\(LLMs.cleanup()?.name ?? "rules only"))")
        let out = await Polisher.polish(text, appName: "Notes")
        print("polished (\(ms(since: t0))): \(out)")
    }

    private static func route(_ said: String) async throws {
        AppIndex.shared.refresh()
        let app = NSWorkspace.shared.frontmostApplication
        let context = ScreenContext.capture(app: app)
        let router = Router()
        print("decider: \(router.decider.name) · apps indexed: \(AppIndex.shared.apps.count) · frontmost: \(context.appName) · on-screen targets: \(context.elements.count) · menu items: \(context.menuItems.count)")
        let t0 = Date()
        let result = try await router.route(said, context: context)
        let total = ms(since: t0)
        switch result {
        case .unsure(let msg):
            print("→ unsure: \(msg)")
        case .action(let a):
            print("→ \(a.summary)\(a.detail.map { "\n   \($0.replacingOccurrences(of: "\n", with: "\n   "))" } ?? "")")
            print(String(format: "   confidence %.2f · risky %@ · %@", a.confidence, a.risky ? "yes" : "no", a.needsConfirmation ? "would ask first" : "would run immediately"))
        }
        print("   decisions \(String(format: "%.0f", router.lastDecisionMs)) ms · total \(total) · spend so far $\(String(format: "%.5f", UsageMeter.estimatedDollars))")
    }

    /// Looks at the frontmost window and prints the step the agent would take. Never acts.
    private static func agentStep(_ goal: String) async throws {
        AppIndex.shared.refresh()
        let app = NSWorkspace.shared.frontmostApplication
        let t0 = Date()
        let elements = AgentLoop.observe(app: app)
        print("frontmost: \(app?.localizedName ?? "none") · controls: \(elements.count) (\(elements.filter(\.editable).count) editable) · observed in \(ms(since: t0))")
        let probe = AgentLoopProbe(goal: goal)
        let t1 = Date()
        let (op, target) = try await probe.decide(elements: elements)
        print("→ \(op) \(target ?? "")")
        print("   decided by \(probe.deciderName) in \(ms(since: t1)) · spend so far $\(String(format: "%.5f", UsageMeter.estimatedDollars))")
    }

    private static func say(_ text: String) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("opennotch-say.aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", file.path, text]
        try p.run()
        p.waitUntilExit()
        try await prepareSpeech()
        let t0 = Date()
        let heard = try await Speech.transcribe(file: file)
        print("heard (\(ms(since: t0))): \(heard)")
        try await route(heard)
    }
}
