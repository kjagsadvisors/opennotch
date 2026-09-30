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
        guard ["--transcribe", "--polish", "--route", "--say", "--agent-step", "--speak", "--context", "--do", "--test-keys"].contains(flag) else { return false }

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
                case "--speak": try await speak(rest)
                case "--context": context(rest)
                case "--do": try await perform(rest)
                case "--test-keys": await testKeys()
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

    /// Routes a command and actually runs it (unlike --route):  OpenNotch --do "click pricing"
    private static func perform(_ said: String) async throws {
        AppIndex.shared.refresh()
        let context = ScreenContext.capture(app: targetApp())
        switch try await Router().route(said, context: context) {
        case .unsure(let msg): print("→ unsure: \(msg)")
        case .action(let a):
            let message = try await a.run()
            print("→ did: \(a.summary)" + (message.map { " · \($0)" } ?? ""))
        }
    }

    /// Feeds simulated fn events through the key state machine: hold, double-tap (hands-free),
    /// finishing tap, and a hold again.
    private static func testKeys() async {
        let keys = KeyboardTap()
        var log: [String] = []
        keys.onPress = { log.append("press \($0)") }
        keys.onRelease = { log.append("release \($0)") }
        keys.onLatch = { log.append("hands-free \($0)") }
        func fn(_ down: Bool) {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: down)!
            e.type = .flagsChanged
            e.flags = down ? .maskSecondaryFn : []
            _ = keys.handle(type: .flagsChanged, event: e)
        }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        log.append("— hold 1s"); fn(true); await wait(1); fn(false)
        await wait(0.6)
        log.append("— double-tap"); fn(true); await wait(0.08); fn(false); await wait(0.12); fn(true); await wait(0.08); fn(false)
        log.append("— talk 1s, then tap to finish"); await wait(1); fn(true); await wait(0.08); fn(false)
        await wait(0.6)
        log.append("— hold again"); fn(true); await wait(0.5); fn(false)
        print(log.joined(separator: "\n"))
    }

    /// The app a test acts on: OPENNOTCH_TARGET_APP (a running app's name) or the frontmost app.
    private static func targetApp() -> NSRunningApplication? {
        if let name = ProcessInfo.processInfo.environment["OPENNOTCH_TARGET_APP"] {
            return NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
        }
        return NSWorkspace.shared.frontmostApplication
    }

    /// What OpenNotch can see and click in an app:  OpenNotch --context "Google Chrome"
    private static func context(_ name: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else {
            return print("\(name) isn't running")
        }
        AX.enableAccessibility(for: app)
        let t0 = Date()
        let c = ScreenContext.capture(app: app)
        print("\(c.appName) · window \"\(c.windowTitle ?? "-")\" · \(c.elements.count) targets · \(c.menuItems.count) menu items · \(ms(since: t0))")
        for e in c.elements.prefix(60) { print("  " + e.label) }
    }

    /// Synthesizes a spoken reply with the Kokoro voice and writes it to /tmp/opennotch-speak.wav.
    private static func speak(_ text: String) async throws {
        #if canImport(FluidAudio)
        let t0 = Date()
        try await KokoroVoice.shared.prepare()
        print("voice ready (\(ms(since: t0)))")
        let t1 = Date()
        guard let wav = try await KokoroVoice.shared.wav(text) else { return print("voice not ready") }
        let url = URL(fileURLWithPath: "/tmp/opennotch-speak.wav")
        try wav.write(to: url)
        print("spoke \(wav.count / 48_000 * 10 / 10)s of audio in \(ms(since: t1)) → \(url.path)")
        #else
        print("Built without FluidAudio")
        #endif
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
        let app = targetApp()
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
