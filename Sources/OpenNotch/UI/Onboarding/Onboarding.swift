import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

/// One place for the product name, so renaming (e.g. once the domain is picked) is a one-line change.
enum Brand {
    static let name = "OpenNotch"
}

/// First-run experience: a full-screen intro, then a guided window that gets permissions,
/// verifies the talk keys, and has the user dictate and command once before they're done.
@MainActor
final class Onboarding: ObservableObject {
    static let shared = Onboarding()

    enum IntroPhase { case splash, name, greeting }

    enum Step: Int, CaseIterable {
        case permissions, keyCheck, dictationIntro, tryDictation, speed, command, account, paywall, done
    }

    @Published var introPhase: IntroPhase = .splash
    @Published var step: Step = .permissions
    @Published var name: String
    @Published var tryText = ""
    @Published var narrationOn: Bool {
        didSet { UserDefaults.standard.set(narrationOn, forKey: "narrationOn"); if !narrationOn { stopNarration() } }
    }

    /// Design-review mode (dev CLI): no narration, no permission polling side effects.
    var previewMode = false

    private var overlay: NSWindow?
    private var window: NSWindow?
    private var guide: NSPanel?
    private var pollTimer: Timer?
    private var narrator: AVAudioPlayer?

    static var isComplete: Bool { UserDefaults.standard.bool(forKey: "onboardingComplete") }

    /// While onboarding is up, people can try everything before they've made an account.
    var isOpen: Bool { overlay != nil || window?.isVisible == true }

    private init() {
        UserDefaults.standard.register(defaults: ["narrationOn": true])
        narrationOn = UserDefaults.standard.bool(forKey: "narrationOn")
        name = UserDefaults.standard.string(forKey: "userFirstName")
            ?? NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }

    var progress: Double {
        Double(step.rawValue + 1) / Double(Step.allCases.count)
    }

    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "friend" : name }

    // MARK: - Intro

    func start() {
        introPhase = .splash
        step = .permissions
        showIntro()
    }

    func presentIntroForPreview() { showIntro() }

    private func showIntro() {
        guard let screen = NSScreen.main else { return showWindow() }
        let o = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        o.isOpaque = false
        o.backgroundColor = .clear
        o.level = .floating
        o.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        o.contentView = NSHostingView(rootView: IntroView(model: self))
        o.alphaValue = 0
        o.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.6; o.animator().alphaValue = 1 }
        overlay = o
        say("welcome")
    }

    func beginNameEntry() {
        introPhase = .name
        say("askName")
    }

    func submitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(trimmed, forKey: "userFirstName")
        introPhase = .greeting
        say("greeting")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in self?.finishIntro() }
    }

    func finishIntro() {
        guard let o = overlay else { return }
        overlay = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.45; o.animator().alphaValue = 0 }, completionHandler: {
            o.orderOut(nil)
        })
        showWindow()
    }

    // MARK: - Guided window

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.contentView = NSHostingView(rootView: OnboardingView(model: self))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        startPolling()
        announce()
        if previewMode, let w = window { print("window \(w.windowNumber)"); fflush(stdout) }
    }

    /// Permissions change in System Settings, outside our process; watch for them while visible.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                AppController.shared.refreshStatus()
                if AX.isTrusted { self.hideAccessibilityGuide() }
                if self.window?.isVisible != true { self.pollTimer?.invalidate() }
            }
        }
    }

    func next() {
        var target = Step(rawValue: step.rawValue + 1) ?? .done
        // No measurement, no speed screen.
        if target == .speed, AppController.shared.lastDictation == nil { target = .command }
        if target == .account, Account.isSignedIn { target = .paywall }
        step = target
        announce()
    }

    func back() {
        var target = Step(rawValue: step.rawValue - 1) ?? .permissions
        if target == .account, Account.isSignedIn { target = .command }
        if target == .speed, AppController.shared.lastDictation == nil { target = .tryDictation }
        step = target
        announce()
    }

    /// Jumps straight to sign-in (for someone who finished an older onboarding without an account).
    func showAccount() {
        step = .account
        showWindow()
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        stopNarration()
        pollTimer?.invalidate()
        hideAccessibilityGuide()
        window?.orderOut(nil)
        window = nil
    }

    // MARK: - Permissions

    func requestMicrophone() { AppController.shared.requestMicrophone() }

    func requestAccessibility() {
        AX.promptForTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        showAccessibilityGuide()
    }

    /// A small floating card beside System Settings: what to switch on, and a draggable icon
    /// in case the app isn't in the list yet.
    private func showAccessibilityGuide() {
        guard guide == nil, let screen = NSScreen.main else { return }
        let size = NSSize(width: 420, height: 96)
        let p = NSPanel(contentRect: NSRect(origin: NSPoint(x: screen.visibleFrame.minX + 32, y: screen.visibleFrame.minY + 32), size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = false
        p.contentView = NSHostingView(rootView: AccessibilityGuide(onClose: { [weak self] in self?.hideAccessibilityGuide() }))
        p.orderFrontRegardless()
        guide = p
    }

    private func hideAccessibilityGuide() {
        guide?.orderOut(nil)
        guide = nil
    }

    /// Opening at login is on by default: the first time the last screen shows, OpenNotch adds
    /// itself to Login Items. Switching it off there (or later in System Settings) sticks.
    func turnOnLaunchAtLoginByDefault() {
        guard !previewMode, !UserDefaults.standard.bool(forKey: "launchAtLoginDefaulted") else { return }
        UserDefaults.standard.set(true, forKey: "launchAtLoginDefaulted")
        launchAtLogin = true
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                debugLog("login item: \(error)")
            }
            objectWillChange.send()
        }
    }

    // MARK: - Narration

    private func announce() {
        switch step {
        case .speed: if AppController.shared.lastDictation?.speedup != nil { say("speed") }
        case .done: say("done")
        default: say("\(step)")
        }
    }

    /// Plays a recorded narration line (Resources/Narration/<id>.m4a, made by scripts/make-narration.sh
    /// with the open-source Kokoro voice). Missing clips are simply skipped.
    func say(_ clip: String) {
        guard narrationOn, !previewMode,
              let url = Bundle.main.url(forResource: clip, withExtension: "m4a", subdirectory: "Narration") else { return }
        narrator?.stop()
        narrator = try? AVAudioPlayer(contentsOf: url)
        narrator?.play()
    }

    func stopNarration() {
        narrator?.stop()
    }
}

/// Borderless windows can't take keyboard focus by default; the intro needs a text field.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
