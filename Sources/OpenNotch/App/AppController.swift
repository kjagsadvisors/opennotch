import AppKit
import AVFoundation

/// How fast the user just talked, for the onboarding payoff screen.
struct DictationStat {
    static let typingWPM = 40

    let words: Int
    let seconds: Double

    var wpm: Int { Int((Double(words) / max(seconds, 1) * 60).rounded()) }
    var speedup: Int { max(1, Int((Double(wpm) / Double(Self.typingWPM)).rounded())) }
}

/// Wires hotkey → microphone → speech → (cleanup | router) → action, and drives the notch.
@MainActor
final class AppController: ObservableObject, AgentPresenter {
    static let shared = AppController()

    let notch = NotchState()
    private lazy var window = NotchWindowController(state: notch)
    private let keys = KeyboardTap()
    private let recorder = Recorder()

    @Published private(set) var speechReady = false
    @Published private(set) var parakeetState = Speech.parakeetState
    @Published private(set) var accessibilityGranted = AX.isTrusted
    @Published private(set) var micGranted = Recorder.permission == .authorized
    @Published private(set) var statusLine = "Starting…"
    @Published private(set) var lastDictation: DictationStat?
    @Published private(set) var lastCommand: String?
    @Published private(set) var commandCount = 0

    private var transcriber: DictationSession?
    private var sessionMode: Mode?
    private var sessionStart = Date()
    private var targetApp: NSRunningApplication?
    private var contextTask: Task<ScreenContext, Never>?
    private var hideWork: DispatchWorkItem?
    private var pending: PlannedAction?
    private var stepConfirmation: CheckedContinuation<Bool, Never>?
    private var runningTask: Task<Void, Never>?
    private var speculationTask: Task<Void, Never>?
    private var speculated: (key: String, result: RouteResult)?
    private var lastSpeculatedKey = ""

    func bootstrap() {
        Pref.registerDefaults()
        window.show()
        AppIndex.shared.refresh()
        wireKeys()
        startTapWhenTrusted()

        Task {
            // First run asks for the mic inside onboarding, after explaining why.
            if Onboarding.isComplete, Recorder.permission == .notDetermined { micGranted = await Recorder.requestPermission() }
            do {
                Speech.onStateChange = { [weak self] in
                    self?.parakeetState = Speech.parakeetState
                    self?.refreshStatus()
                }
                try await Speech.prepare { [weak self] msg in
                    Task { @MainActor in self?.flash(msg, icon: "arrow.down.circle", seconds: 4) }
                }
                speechReady = true
                refreshStatus()
            } catch {
                statusLine = "Speech model unavailable: \(error.localizedDescription)"
            }
        }

        // Pick up newly installed apps now and then.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in AppIndex.shared.refresh() }

        AgentHost.presenter = self
        if !Onboarding.isComplete { Onboarding.shared.start() }
        Pro.shared.onActivated = { [weak self] in
            self?.flash("\(Brand.name) Pro is on", detail: "Claude now cleans up everything you dictate.", icon: "checkmark.seal.fill", seconds: 4)
        }
    }

    func recordPreviewDictation(words: Int, seconds: Double) {
        lastDictation = DictationStat(words: words, seconds: seconds)
    }

    func refreshStatus() {
        accessibilityGranted = AX.isTrusted
        micGranted = Recorder.permission == .authorized
        if !accessibilityGranted { statusLine = "Needs Accessibility permission" }
        else if !micGranted { statusLine = "Needs Microphone permission" }
        else if !speechReady { statusLine = "Loading speech model…" }
        else {
            let d = TriggerKey(rawValue: Pref.string(Pref.dictationKey))?.label ?? "Fn"
            let c = TriggerKey(rawValue: Pref.string(Pref.commandKey))?.label ?? "Right Option"
            statusLine = "Hold \(d) to dictate · \(c) to command"
        }
    }

    /// The event tap can only be created once Accessibility is granted; poll until then.
    private func startTapWhenTrusted() {
        if keys.start() {
            refreshStatus()
            return
        }
        refreshStatus()
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return timer.invalidate() }
                if self.keys.start() {
                    timer.invalidate()
                    self.refreshStatus()
                }
            }
        }
    }

    func requestAccessibility() { AX.promptForTrust() }

    func requestMicrophone() {
        Task {
            if Recorder.permission == .notDetermined {
                micGranted = await Recorder.requestPermission()
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
            refreshStatus()
        }
    }

    private func wireKeys() {
        keys.onPress = { [weak self] mode in Task { @MainActor in self?.begin(mode) } }
        keys.onRelease = { [weak self] mode in Task { @MainActor in self?.end(mode) } }
        keys.onChord = { [weak self] in Task { @MainActor in self?.cancelListening() } }
        keys.onLatch = { [weak self] _ in Task { @MainActor in self?.notch.handsFree = true } }
        keys.onEscape = { [weak self] in Task { @MainActor in self?.escape() } }
        keys.onReturn = { [weak self] in Task { @MainActor in self?.confirmPending() } }
    }

    // MARK: - Listening

    private func begin(_ mode: Mode) {
        guard sessionMode == nil else { return }
        // An account is required, but onboarding lets people try dictation and a command first.
        guard Account.isSignedIn || Onboarding.shared.isOpen else {
            flash("Sign in to keep using \(Brand.name)", detail: "Click to sign in", icon: "person.crop.circle", seconds: 4) {
                Onboarding.shared.showAccount()
            }
            return
        }
        if pending != nil { dismissConfirm() }
        guard speechReady, let format = Speech.audioFormat else {
            flash(speechReady ? "Microphone unavailable" : "Speech model still loading…", icon: "hourglass", seconds: 2)
            return
        }
        guard Recorder.permission == .authorized else {
            requestMicrophone()
            flash("OpenNotch needs microphone access", icon: "mic.slash", seconds: 3, error: true)
            return
        }

        Onboarding.shared.stopNarration()
        sessionMode = mode
        sessionStart = Date()
        targetApp = NSWorkspace.shared.frontmostApplication
        if mode == .command {
            // Read the screen while the user is still talking, so it costs no latency.
            let app = targetApp
            contextTask = Task.detached(priority: .userInitiated) { ScreenContext.capture(app: app) }
        }

        speculated = nil
        lastSpeculatedKey = ""
        let t = Speech.makeSession()
        t.onUpdate = { [weak self] text in
            self?.notch.transcript = text
            if mode == .command { self?.speculate(text) }
        }
        transcriber = t
        recorder.onBuffer = { [t] buf in t.append(buf) }
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.notch.level = level }
        }
        do {
            try recorder.start(targetFormat: format)
        } catch {
            sessionMode = nil
            flash("Mic error: \(error.localizedDescription)", icon: "mic.slash", seconds: 3, error: true)
            return
        }
        t.start()

        hideWork?.cancel()
        notch.mode = mode
        notch.transcript = ""
        notch.isError = false
        notch.phase = .listening
        keys.captureEscape = true
    }

    private func end(_ mode: Mode) {
        guard sessionMode == mode, let t = transcriber else { return }
        // A quick tap isn't a hold-to-talk.
        if Date().timeIntervalSince(sessionStart) < 0.25 { return cancelListening() }

        recorder.stop()
        let spokenFor = Date().timeIntervalSince(sessionStart)
        sessionMode = nil
        transcriber = nil
        keys.captureEscape = false
        notch.level = 0
        notch.handsFree = false
        notch.phase = .working
        notch.title = "Listening"

        let app = targetApp
        let contextTask = self.contextTask
        self.contextTask = nil

        Task {
            let text = await t.finish()
            guard !text.isEmpty else { return hide() }
            switch mode {
            case .dictation:
                notch.title = "Cleaning"
                let polished = await Polisher.polish(text, appName: app?.localizedName)
                TextInserter.insert(polished)
                lastDictation = DictationStat(words: polished.split(separator: " ").count, seconds: spokenFor)
                hide()
                maybeNudgeToPro(raw: text)
            case .command:
                notch.title = "Thinking"
                speculationTask?.cancel()
                // Decided while you were still talking: nothing left to wait for.
                if let s = speculated, s.key == Self.normalize(text) {
                    await handle(s.result, said: text)
                } else {
                    let context = await contextTask?.value ?? ScreenContext.capture(app: app)
                    await handleCommand(text, context: context)
                }
            }
        }
    }

    private func cancelListening() {
        guard sessionMode != nil else { return }
        speculationTask?.cancel()
        recorder.stop()
        transcriber?.cancel()
        transcriber = nil
        sessionMode = nil
        contextTask?.cancel()
        contextTask = nil
        keys.captureEscape = false
        keys.resetHold()
        notch.handsFree = false
        hide()
    }

    private func escape() {
        if let c = stepConfirmation {
            stepConfirmation = nil
            c.resume(returning: false)
        }
        if let task = runningTask {
            task.cancel()
            runningTask = nil
            flash("Stopped", icon: "stop.circle", seconds: 1.2)
            return
        }
        if sessionMode != nil { cancelListening() }
        else if pending != nil { dismissConfirm() }
        else { hide() }
    }

    // MARK: - Commands

    private func handleCommand(_ text: String, context: ScreenContext) async {
        do {
            await handle(try await Router().route(text, context: context), said: text)
        } catch {
            flash("Couldn't do that", detail: error.localizedDescription, icon: "exclamationmark.triangle", seconds: 4, error: true)
        }
    }

    private func handle(_ result: RouteResult, said text: String) async {
        switch result {
        case .unsure(let msg):
            flash(msg, detail: "“\(text)”", icon: "questionmark.circle", seconds: 3.5, error: true)
        case .action(let action):
            if action.needsConfirmation {
                askConfirm(action)
            } else {
                await run(action)
            }
        }
    }

    // MARK: - Speculation

    static func normalize(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Decides the command on each partial transcript while the key is still held. With Jev each
    /// decision costs a hundredth of a cent, so speculating is nearly free; if the final words match,
    /// the answer is already here. Safe, confident app launches start early (hidden).
    private func speculate(_ partial: String) {
        guard Deciders.isCheap else { return }
        let key = Self.normalize(partial)
        guard key != lastSpeculatedKey, key.split(separator: " ").count >= 2 else { return }
        lastSpeculatedKey = key
        speculationTask?.cancel()
        let contextTask = self.contextTask
        let app = targetApp
        speculationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let context = await contextTask?.value ?? ScreenContext.capture(app: app)
            guard let result = try? await Router().route(partial, context: context), !Task.isCancelled else { return }
            guard let self else { return }
            self.speculated = (key, result)
            if case .action(let action) = result, action.confidence >= 0.9, !action.risky { action.prewarm?() }
        }
    }

    // MARK: - Agent presenter

    func agentProgress(_ title: String, detail: String?) {
        hideWork?.cancel()
        notch.title = title
        notch.detail = detail
        notch.icon = "bolt.fill"
        notch.isError = false
        notch.phase = .message
    }

    func agentConfirm(_ title: String, detail: String?) async -> Bool {
        await withCheckedContinuation { continuation in
            stepConfirmation?.resume(returning: false)
            stepConfirmation = continuation
            hideWork?.cancel()
            notch.title = title
            notch.detail = detail
            notch.icon = "hand.raised.fill"
            notch.isError = false
            notch.onConfirm = { [weak self] in self?.confirmPending() }
            notch.onCancel = { [weak self] in self?.dismissConfirm() }
            notch.phase = .confirm
            window.setInteractive(true)
            keys.captureConfirmKeys = true
        }
    }

    private func run(_ action: PlannedAction) async {
        let task = Task { await self.execute(action) }
        runningTask = task
        keys.captureEscape = true
        await task.value
        if runningTask == task { runningTask = nil }
        keys.captureEscape = false
    }

    private func execute(_ action: PlannedAction) async {
        notch.phase = .working
        notch.title = "Working"
        do {
            let message = try await action.run()
            lastCommand = action.summary
            commandCount += 1
            if let message {
                flash(action.summary, detail: message, icon: action.icon, seconds: max(6, Double(message.count) / 15))
            } else {
                flash(action.summary, icon: "checkmark.circle.fill", seconds: 1.2)
            }
        } catch is CancellationError {
            return
        } catch {
            flash("Couldn't \(action.summary.lowercased())", detail: error.localizedDescription, icon: "exclamationmark.triangle", seconds: 4, error: true)
        }
    }

    private func askConfirm(_ action: PlannedAction) {
        pending = action
        hideWork?.cancel()
        notch.title = action.summary
        notch.detail = action.detail
        notch.icon = action.icon
        notch.isError = false
        notch.onConfirm = { [weak self] in self?.confirmPending() }
        notch.onCancel = { [weak self] in self?.dismissConfirm() }
        notch.phase = .confirm
        window.setInteractive(true)
        keys.captureConfirmKeys = true
    }

    private func confirmPending() {
        if let c = stepConfirmation {
            stepConfirmation = nil
            keys.captureConfirmKeys = false
            window.setInteractive(false)
            c.resume(returning: true)
            return
        }
        guard let action = pending else { return }
        pending = nil
        keys.captureConfirmKeys = false
        window.setInteractive(false)
        Task { await run(action) }
    }

    private func dismissConfirm() {
        if let c = stepConfirmation {
            stepConfirmation = nil
            keys.captureConfirmKeys = false
            window.setInteractive(false)
            c.resume(returning: false)
            return
        }
        pending = nil
        keys.captureConfirmKeys = false
        window.setInteractive(false)
        hide()
    }

    // MARK: - Notch helpers

    /// Free users whose dictation needed real cleanup hear about Pro, at most once a day and never
    /// in their first few dictations.
    private func maybeNudgeToPro(raw: String) {
        guard !Pro.isActive, LLMs.cleanup() == nil, Polisher.needsModel(raw) else { return }
        let d = UserDefaults.standard
        let misses = d.integer(forKey: "freeCleanupMisses") + 1
        d.set(misses, forKey: "freeCleanupMisses")
        let now = Date().timeIntervalSince1970
        guard misses >= 5, now - d.double(forKey: "lastProNudge") > 20 * 3600 else { return }
        d.set(now, forKey: "lastProNudge")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.flash("Pro would have tidied that up", detail: "Claude fixes fillers and “actually no” corrections. Click to try 7 days free.",
                        icon: "sparkles", seconds: 6, tap: { Pro.shared.openCheckout(yearly: true) })
        }
    }

    private func flash(_ title: String, detail: String? = nil, icon: String, seconds: Double, error: Bool = false, tap: (() -> Void)? = nil) {
        hideWork?.cancel()
        notch.title = title
        notch.detail = detail
        notch.icon = icon
        notch.isError = error
        notch.onTap = tap.map { action in { [weak self] in action(); self?.hide() } }
        window.setInteractive(tap != nil)
        notch.phase = .message
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hide() {
        hideWork?.cancel()
        notch.onTap = nil
        notch.phase = .hidden
        notch.transcript = ""
        window.setInteractive(false)
    }
}
