import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: Onboarding

    var body: some View {
        VStack(spacing: 0) {
            ProgressTrack(progress: model.progress)
                .padding(.horizontal, 84)
                .padding(.top, 22)

            ZStack {
                stepView
                    .id(model.step)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 72)

            HStack {
                if model.step != .permissions {
                    Button("Back") { model.back() }.buttonStyle(.glass).controlSize(.large)
                }
                Spacer()
                SpeakerToggle(on: $model.narrationOn)
            }
            .padding(24)
        }
        .frame(width: 980, height: 640)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [.clear, Color.accentColor.opacity(0.10)], startPoint: .center, endPoint: .bottom)
            }
            .ignoresSafeArea()
        }
        .animation(.smooth(duration: 0.45), value: model.step)
    }

    @ViewBuilder private var stepView: some View {
        switch model.step {
        case .permissions: PermissionsStep(model: model)
        case .keyCheck: KeyCheckStep(model: model)
        case .dictationIntro: DictationIntroStep(model: model)
        case .tryDictation: TryDictationStep(model: model)
        case .speed: SpeedStep(model: model)
        case .command: CommandStep(model: model)
        case .paywall: PaywallStep(model: model)
        case .done: DoneStep(model: model)
        }
    }
}

// MARK: - Permissions

private struct PermissionsStep: View {
    @ObservedObject var model: Onboarding
    @ObservedObject private var app = AppController.shared
    @State private var focus: Item = .mic

    enum Item { case mic, accessibility, speech }

    var body: some View {
        HStack(spacing: 56) {
            VStack(alignment: .leading, spacing: 14) {
                StepTitle("Enable the essentials")
                StepBody("Three quick ones. Your voice never leaves this Mac unless you pick a cloud model later.")
                    .padding(.bottom, 6)
                PermissionCard(icon: "mic.fill", title: "Hear you",
                               detail: "Microphone access, used only while you hold your talk key.",
                               granted: app.micGranted, expanded: focus == .mic,
                               actionTitle: "Allow", action: model.requestMicrophone) { focus = .mic }
                PermissionCard(icon: "hand.point.up.left.fill", title: "Type and click for you",
                               detail: "Accessibility access lets \(Brand.name) paste your words and press the buttons you name.",
                               granted: app.accessibilityGranted, expanded: focus == .accessibility,
                               actionTitle: "Open System Settings", action: model.requestAccessibility) { focus = .accessibility }
                speechCard
                Button("Continue") { model.next() }
                    .primaryAction()
                    .disabled(!(app.micGranted && app.accessibilityGranted))
                    .padding(.top, 8)
            }
            .frame(width: 400)

            PermissionIllustration(item: focus, granted: granted(focus))
                .frame(maxWidth: .infinity)
        }
        .onAppear(perform: advance)
        .onChange(of: app.micGranted) { advance() }
        .onChange(of: app.accessibilityGranted) { advance() }
    }

    @ViewBuilder private var speechCard: some View {
        if Speech.isParakeetBuiltIn {
            PermissionCard(icon: "waveform", title: "Download the speech model",
                           detail: speechDetail,
                           granted: app.parakeetState == .ready, expanded: focus == .speech,
                           busy: app.parakeetState == .downloading,
                           actionTitle: app.parakeetState == .notDownloaded ? "Download (about 600 MB)" : "Try again",
                           action: Speech.downloadParakeet) { focus = .speech }
        } else {
            PermissionCard(icon: "waveform", title: "Understand speech on-device",
                           detail: "Apple's speech model downloads once. Transcription is private and free.",
                           granted: app.speechReady, expanded: focus == .speech, busy: !app.speechReady,
                           actionTitle: nil, action: {}) { focus = .speech }
        }
    }

    private var speechDetail: String {
        if case .failed(let reason) = app.parakeetState { return "The download didn't finish: \(reason)" }
        if app.parakeetState == .downloading { return "Downloading Parakeet. You can keep going; dictation works meanwhile." }
        return "Parakeet, NVIDIA's open speech model, runs on your Mac's Neural Engine. One download; after that transcription is instant, private and free."
    }

    private func granted(_ i: Item) -> Bool {
        switch i {
        case .mic: return app.micGranted
        case .accessibility: return app.accessibilityGranted
        case .speech: return Speech.isParakeetBuiltIn ? app.parakeetState == .ready : app.speechReady
        }
    }

    private func advance() {
        if !app.micGranted { focus = .mic } else if !app.accessibilityGranted { focus = .accessibility } else { focus = .speech }
    }
}

/// Shows what the user is about to see, so the system prompt isn't a surprise.
private struct PermissionIllustration: View {
    let item: PermissionsStep.Item
    let granted: Bool
    @State private var toggled = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.background.secondary)
            Group {
                switch item {
                case .mic: micPrompt
                case .accessibility: settingsList
                case .speech: speechModel
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        .frame(height: 440)
        .animation(.smooth(duration: 0.35), value: item)
        .task(id: item) {
            toggled = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                withAnimation(.snappy) { toggled.toggle() }
            }
        }
    }

    private var appIcon: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)).resizable().frame(width: 52, height: 52)
    }

    private var micPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            appIcon
            Text("“\(Brand.name)” would like to access the microphone.").font(.headline)
            Text("\(Brand.name) listens only while you hold your talk key.").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text("Don't Allow").frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(Capsule().fill(.quaternary))
                Text("Allow").frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 3).scaleEffect(toggled ? 1.12 : 1).opacity(toggled ? 0 : 1))
            }
            .font(.callout.weight(.medium))
        }
        .padding(22)
        .frame(width: 300)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var settingsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left"); Image(systemName: "chevron.right")
                Text("Accessibility").font(.headline).padding(.leading, 6)
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 14)
            VStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack {
                        RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(width: 22, height: 22)
                        RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 110, height: 9)
                        Spacer()
                        Toggle("", isOn: .constant(false)).toggleStyle(.switch).labelsHidden().disabled(true)
                    }
                    .padding(12)
                    Divider()
                }
                HStack {
                    appIcon.frame(width: 22, height: 22).scaleEffect(22 / 52)
                    Text(Brand.name).font(.callout.weight(.medium))
                    Spacer()
                    Toggle("", isOn: .constant(granted || toggled)).toggleStyle(.switch).labelsHidden()
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.08))
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(.background))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(22)
        .frame(width: 360)
    }

    private var speechModel: some View {
        VStack(spacing: 18) {
            Image(systemName: granted ? "checkmark.seal.fill" : "waveform")
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(granted ? Color.green : Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: !granted)
                .contentTransition(.symbolEffect(.replace))
            Text(granted ? "Speech model ready" : Speech.isParakeetBuiltIn ? "NVIDIA Parakeet" : "Preparing speech model…").font(.headline)
            Text("Runs on your Mac's Neural Engine, about 100× faster than real time").font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Key check

private struct KeyCheckStep: View {
    @ObservedObject var model: Onboarding
    @State private var dictationKey = TriggerKey.current(.dictation)
    @State private var commandKey = TriggerKey.current(.command)
    @State private var held: Set<TriggerKey> = []
    @State private var changing = false
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 10) {
                StepTitle("Hold each key. Does it light up?")
                StepBody("These are the only shortcuts you need.")
            }
            HStack(spacing: 60) {
                keyColumn(dictationKey, title: "Dictate")
                keyColumn(commandKey, title: "Command")
            }
            .padding(.vertical, 8)

            if changing {
                VStack(spacing: 14) {
                    Picker("Dictate", selection: $dictationKey) { ForEach(TriggerKey.allCases) { Text($0.label).tag($0) } }
                    Picker("Command", selection: $commandKey) { ForEach(TriggerKey.allCases) { Text($0.label).tag($0) } }
                    HStack(spacing: 6) {
                        Text("If fn opens emoji or dictation, set “Press 🌐 key to” to Do Nothing.").foregroundStyle(.secondary)
                        Button("Keyboard Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                        .buttonStyle(.link)
                    }
                    .font(.callout)
                }
                .frame(width: 520)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 12) {
                Button(changing ? "Done" : "No, change keys") { withAnimation { changing.toggle() } }
                    .buttonStyle(.glass).controlSize(.extraLarge)
                Button("Yes, both light up") { model.next() }
                    .primaryAction()
            }
        }
        .onChange(of: dictationKey) { _, k in UserDefaults.standard.set(k.rawValue, forKey: Pref.dictationKey) }
        .onChange(of: commandKey) { _, k in UserDefaults.standard.set(k.rawValue, forKey: Pref.commandKey) }
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
                for key in TriggerKey.allCases where Int64(e.keyCode) == key.keyCode {
                    if e.modifierFlags.contains(key.nsFlag) { held.insert(key) } else { held.remove(key) }
                }
                return e
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    private func keyColumn(_ key: TriggerKey, title: String) -> some View {
        VStack(spacing: 14) {
            Keycap(key, lit: held.contains(key), scale: 1.7)
            Text(title).font(.headline).foregroundStyle(held.contains(key) ? Color.accentColor : .secondary)
        }
    }
}

// MARK: - Dictation intro

private struct DictationIntroStep: View {
    @ObservedObject var model: Onboarding

    var body: some View {
        HStack(spacing: 56) {
            VStack(alignment: .leading, spacing: 16) {
                StepTitle("Dictation")
                StepBody("Hold \(TriggerKey.current(.dictation).capLabel) and talk like you normally would. \(Brand.name) types what you meant: fillers gone, corrections applied, in any app.")
                HStack(spacing: 12) {
                    Button("Continue") { model.next() }.primaryAction()
                    Button("Skip dictation") {
                        model.step = .tryDictation
                        model.next()
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.top, 18)
            }
            .frame(width: 380)
            DictationDemo().frame(maxWidth: .infinity)
        }
    }
}

/// Looping demo: messy speech in, clean text out.
private struct DictationDemo: View {
    private let spoken = "“um, so the launch is Tuesday… actually no, Thursday”"
    private let typed = "So the launch is Thursday."
    @State private var showSpoken = false
    @State private var listening = false
    @State private var shown = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.36, blue: 0.78), Color(red: 0.46, green: 0.72, blue: 0.96)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(.red).frame(width: 11)
                    Circle().fill(.yellow).frame(width: 11)
                    Circle().fill(.green).frame(width: 11)
                    Text("Notes").font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.8)).padding(.leading, 8)
                    Spacer()
                }
                .padding(14)
                HStack(spacing: 1) {
                    Text(shown).font(.title3).foregroundStyle(.white)
                    Rectangle().fill(.white.opacity(0.8)).frame(width: 2, height: 22)
                    Spacer()
                }
                .padding(.horizontal, 18)
                Spacer()
            }
            .frame(width: 380, height: 180)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.13)))
            .padding(.bottom, 150)

            VStack(spacing: 12) {
                Text(spoken)
                    .font(.callout.italic())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.clear, in: Capsule())
                    .opacity(showSpoken ? 1 : 0)
                HStack(spacing: 3) {
                    ForEach(0..<9, id: \.self) { i in
                        Capsule().fill(.white)
                            .frame(width: 3, height: listening ? CGFloat([8, 16, 22, 12, 26, 14, 20, 10, 7][i]) : 4)
                    }
                }
                .frame(width: 110, height: 34)
                .background(Capsule().fill(.black))
                .animation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true), value: listening)
            }
            .padding(.bottom, 28)
        }
        .frame(height: 440)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .task { await loop() }
    }

    private func loop() async {
        while !Task.isCancelled {
            shown = ""
            withAnimation(.smooth) { showSpoken = true; listening = true }
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation(.smooth) { listening = false; showSpoken = false }
            for ch in typed {
                shown.append(ch)
                try? await Task.sleep(nanoseconds: 35_000_000)
            }
            try? await Task.sleep(nanoseconds: 2_400_000_000)
        }
    }
}

// MARK: - Try dictation

private struct TryDictationStep: View {
    @ObservedObject var model: Onboarding
    @FocusState private var focused: Bool
    @State private var tips = false

    private var script: String {
        "Hi Alex, it was great meeting you today. Do you have time on Monday to follow up? Best, \(model.displayName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle("Try dictating")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill").foregroundStyle(Color.accentColor)
                    Text("New Message").font(.headline)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("To:").foregroundStyle(.tertiary); Text("alex@example.com").foregroundStyle(.secondary) }
                    GridRow { Text("Subject:").foregroundStyle(.tertiary); Text("Great meeting you").foregroundStyle(.secondary) }
                }
                .font(.callout)
                Divider()
                HStack(spacing: 8) {
                    Text("Hold")
                    Keycap(TriggerKey.current(.dictation), scale: 0.62)
                    Text("and say, then let go:")
                }
                .font(.callout)
                Text("“\(script)”").font(.callout.weight(.semibold).italic())
                TextEditor(text: $model.tryText)
                    .font(.title3)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(height: 120)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.background))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1)))
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.background.secondary))

            HStack {
                if tips {
                    Text("Check the notch lights up while you hold the key. Speak after it appears, and keep holding until you finish.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Not working?") { withAnimation { tips.toggle() } }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Next") { model.next() }
                    .primaryAction()
                    .disabled(model.tryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: 720)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true } }
    }
}

// MARK: - Speed

private struct SpeedStep: View {
    @ObservedObject var model: Onboarding
    @ObservedObject private var app = AppController.shared
    @State private var shownWPM = 0

    var body: some View {
        let stat = app.lastDictation
        VStack(spacing: 14) {
            Text("You just spoke").font(.title2).foregroundStyle(.secondary)
            Text("\(stat?.speedup ?? 1)x faster")
                .font(.system(size: 76, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [.primary, .accentColor], startPoint: .leading, endPoint: .trailing))
            Text("than the average person types").font(.title2).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                StatCard(title: "Average typing", value: DictationStat.typingWPM, unit: "words/min")
                StatCard(title: "Your voice", value: shownWPM, unit: "words/min", highlight: true)
            }
            .padding(.vertical, 20)
            Button("Continue") { model.next() }.primaryAction()
        }
        .task {
            // Count up for a little moment of delight.
            let target = stat?.wpm ?? 0
            for v in stride(from: 0, through: target, by: max(1, target / 30)) {
                withAnimation(.snappy) { shownWPM = v }
                try? await Task.sleep(nanoseconds: 22_000_000)
            }
            withAnimation(.snappy) { shownWPM = target }
        }
    }
}

// MARK: - Command

private struct CommandStep: View {
    @ObservedObject var model: Onboarding
    @ObservedObject private var app = AppController.shared
    @State private var startCount = 0

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                StepTitle("Tell your Mac what to do")
                StepBody("Commands open apps, press buttons, search, change settings and answer questions.")
            }
            VStack(alignment: .leading, spacing: 18) {
                row(1) {
                    Text("Hold")
                    Keycap(TriggerKey.current(.command), scale: 0.75)
                }
                row(2) { Text("Say “Open Calculator”") }
                if app.commandCount > startCount, let last = app.lastCommand {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                        Text(last).font(.title3.weight(.medium))
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(28)
            .frame(width: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.background.secondary))
            .animation(.smooth, value: app.commandCount)

            Text("Also try: “Turn the volume down” · “Search for flights to Lisbon” · “What's 15% of 80?”")
                .font(.callout).foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Skip") { model.next() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Next") { model.next() }.primaryAction()
            }
        }
        .onAppear { startCount = app.commandCount }
    }

    private func row<Content: View>(_ n: Int, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 14) {
            Text("\(n)").font(.headline).foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30).background(Circle().fill(Color.accentColor.opacity(0.12)))
            content().font(.title2)
        }
    }
}

// MARK: - Models

/// The trial offer, shown right after the user has felt the speed. Free stays one quiet click away:
/// the app is open source, so this persuades rather than blocks.
private struct PaywallStep: View {
    @ObservedObject var model: Onboarding
    @ObservedObject private var pro = Pro.shared
    @AppStorage(Pref.deciderBackend) private var decider = "auto"
    @AppStorage(Pref.llmProvider) private var provider = "anthropic"
    @AppStorage(Pref.cleanupProvider) private var cleanup = "auto"
    @State private var yearly = true
    @State private var waitingForKey = false
    @State private var license = ""
    @State private var ownKeyOpen = false
    @State private var anthropicKey = Secrets.get(.anthropic) ?? ""

    var body: some View {
        HStack(alignment: .center, spacing: 56) {
            VStack(alignment: .leading, spacing: 14) {
                if pro.status == .active {
                    activated
                } else {
                    StepTitle(waitingForKey ? "Almost there" : "Start your 7-day free trial")
                    if waitingForKey { licenseEntry } else { plans }
                }
            }
            .frame(width: 420)

            benefits.frame(maxWidth: .infinity)
        }
        .animation(.smooth, value: waitingForKey)
        .animation(.smooth, value: pro.status)
        .onChange(of: pro.status) { _, s in
            if s == .active {
                decider = "auto"; provider = "anthropic"; cleanup = "auto"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { model.next() }
            }
        }
        // Coming back from checkout with the key copied from the email fills it in automatically.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard waitingForKey, license.isEmpty,
                  let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  clip.uppercased().hasPrefix("OPENNOTCH"), clip.count < 120 else { return }
            license = clip
            Task { await pro.activate(clip) }
        }
    }

    private var plans: some View {
        VStack(alignment: .leading, spacing: 14) {
            planCard(yearly: true, title: "Yearly", price: "$6.67", detail: "$79.99 billed yearly", badge: "Save 33%")
            planCard(yearly: false, title: "Monthly", price: "$9.99", detail: "billed monthly", badge: nil)

            VStack(spacing: 10) {
                Text("No payment due now").font(.headline).frame(maxWidth: .infinity)
                Button {
                    pro.openCheckout(yearly: yearly)
                    waitingForKey = true
                } label: {
                    Text("Start my 7-day free trial").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryGlassButtonStyle())
                Text(yearly ? "Then $79.99 per year. Cancel anytime." : "Then $9.99 per month. Cancel anytime.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            .padding(.top, 6)

            HStack {
                Button("I have a license key") { waitingForKey = true }
                Spacer()
                Button("Continue with free") {
                    decider = "auto"; provider = "anthropic"
                    cleanup = Secrets.get(.anthropic) == nil ? "rules" : "auto"
                    model.next()
                }
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }

    private var licenseEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finish checkout in your browser. Your license key arrives by email; copy it and come back. \(Brand.name) picks it up automatically.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("OPENNOTCH-…", text: $license)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await pro.activate(license) } }
                Button("Activate") { Task { await pro.activate(license) } }
                    .buttonStyle(PrimaryGlassButtonStyle(compact: true))
                    .disabled(license.trimmingCharacters(in: .whitespaces).isEmpty || pro.status == .checking)
            }
            if pro.status == .checking { ProgressView().controlSize(.small) }
            if case .problem(let message) = pro.status { Text(message).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Back to plans") { waitingForKey = false }
                Spacer()
                Button("Find my key") { pro.openManage() }
            }
            .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)

            DisclosureGroup("Use my own Anthropic API key instead", isExpanded: $ownKeyOpen) {
                SecureField("sk-ant-…", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: anthropicKey) { _, v in Secrets.set(.anthropic, v) }
                    .padding(.top, 6)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
    }

    private var activated: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 48)).foregroundStyle(.green)
            StepTitle("You're Pro.")
            StepBody("Claude now cleans up everything you dictate. Thanks for supporting \(Brand.name).")
        }
    }

    private func planCard(yearly isYearly: Bool, title: String, price: String, detail: String, badge: String?) -> some View {
        let selected = yearly == isYearly
        return Button { yearly = isYearly } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(price).font(.title2.weight(.semibold))
                Text("/mo").font(.callout).foregroundStyle(.secondary)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge).font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: -14, y: -11)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("With Pro").font(.headline).foregroundStyle(.secondary)
            benefit("sparkles", "Every dictation, cleaned up", "Fillers, false starts and “actually no” corrections fixed by Claude.")
            benefit("command", "Smarter commands", "Understands what you mean, not just exact phrases.")
            benefit("text.bubble", "Answers and rewrites", "Ask questions, or say “make this more formal” on any selection.")
            benefit("key.slash", "Nothing to set up", "No API keys or accounts to manage. Works on up to 3 Macs.")
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.background.secondary))
    }

    private func benefit(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Done

private struct DoneStep: View {
    @ObservedObject var model: Onboarding
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: appeared)
            VStack(spacing: 8) {
                StepTitle("You're all set, \(model.displayName).")
                StepBody("\(Brand.name) lives in your menu bar and your notch.")
            }
            VStack(alignment: .leading, spacing: 14) {
                shortcut(Keycap(TriggerKey.current(.dictation), scale: 0.7), "Hold to dictate")
                shortcut(Keycap(TriggerKey.current(.command), scale: 0.7), "Hold to give a command")
                shortcut(Keycap(label: "esc", scale: 0.7), "Cancel")
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.background.secondary))

            Toggle("Open \(Brand.name) at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                .toggleStyle(.switch)

            Button { model.finish() } label: {
                Text("Start using \(Brand.name)").padding(.horizontal, 8)
            }
            .primaryAction()
            .keyboardShortcut(.defaultAction)
        }
        .onAppear { appeared = true }
    }

    private func shortcut(_ cap: Keycap, _ text: String) -> some View {
        HStack(spacing: 16) {
            cap.frame(width: 64, alignment: .leading)
            Text(text).font(.title3)
        }
    }
}
