import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            ProTab().tabItem { Label("Pro", systemImage: "sparkles") }
            ModelsTab().tabItem { Label("Models", systemImage: "cpu") }
            PermissionsTab(controller: controller).tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralTab: View {
    @AppStorage(Pref.dictationKey) private var dictationKey = TriggerKey.fn.rawValue
    @AppStorage(Pref.commandKey) private var commandKey = TriggerKey.optionCommand.rawValue
    @AppStorage(Pref.polishEnabled) private var polish = true
    @AppStorage(Pref.autoRunConfidence) private var autoRun = 0.8
    @AppStorage(Pref.vocabulary) private var vocabulary = ""
    @AppStorage(Pref.searchURL) private var searchURL = "https://www.google.com/search?q=%s"

    @ObservedObject private var account = Account.shared

    var body: some View {
        Form {
            Section("Account") {
                if let email = account.email {
                    LabeledContent("Signed in as", value: email)
                    Button("Sign Out") { account.signOut() }
                } else {
                    Button("Sign In…") { Onboarding.shared.showAccount() }
                }
            }
            Section("Hold to talk") {
                Picker("Dictate", selection: $dictationKey) {
                    ForEach(TriggerKey.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Command", selection: $commandKey) {
                    ForEach(TriggerKey.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text("If Fn opens the emoji picker, set System Settings › Keyboard › “Press 🌐 key to” › Do Nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dictation") {
                Toggle("Clean up fillers and self-corrections", isOn: $polish)
                TextField("Custom words (comma separated)", text: $vocabulary, axis: .vertical)
                    .lineLimit(2...4)
            }
            UpdatesSection()
            Section("Commands") {
                Slider(value: $autoRun, in: 0.5...1.0, step: 0.05) {
                    Text("Ask before running below \(Int(autoRun * 100))% confidence")
                }
                TextField("Search URL (%s = query)", text: $searchURL)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelsTab: View {
    @ObservedObject private var app = AppController.shared
    @AppStorage(Pref.speechEngine) private var speechEngine = Speech.isParakeetBuiltIn ? "parakeet" : "apple"
    @AppStorage(Pref.parakeetModel) private var parakeetModel = "ultra"
    @AppStorage(Pref.cleanupProvider) private var cleanup = "auto"
    @AppStorage(Pref.deciderBackend) private var decider = "auto"
    @AppStorage(Pref.jevEndpoint) private var jevEndpoint = "https://api.typesafe.ai/v1/systemone"
    @AppStorage(Pref.llmProvider) private var provider = "anthropic"
    @AppStorage(Pref.anthropicModel) private var anthropicModel = "claude-haiku-4-5"
    @AppStorage(Pref.openAIBaseURL) private var openAIBase = "http://localhost:11434/v1"
    @AppStorage(Pref.openAIModel) private var openAIModel = "llama3.2"

    @State private var keys: [Secrets.Name: String] = Dictionary(uniqueKeysWithValues: Secrets.Name.allCases.map { ($0, Secrets.get($0) ?? "") })

    private func key(_ name: Secrets.Name) -> Binding<String> {
        Binding(get: { keys[name] ?? "" }, set: { keys[name] = $0; Secrets.set(name, $0) })
    }

    var body: some View {
        Form {
            Section("Hearing (speech to text, always on this Mac)") {
                Picker("Engine", selection: $speechEngine) {
                    if Speech.isParakeetBuiltIn { Text("NVIDIA Parakeet (recommended)").tag("parakeet") }
                    Text("Apple SpeechAnalyzer").tag("apple")
                }
                if speechEngine == "parakeet" && Speech.isParakeetBuiltIn {
                    Picker("Model", selection: $parakeetModel) {
                        Text("Ultra — most accurate (~600 MB)").tag("ultra")
                        Text("v3 (~450 MB)").tag("v3")
                        Text("Redux — smallest (~220 MB)").tag("redux")
                    }
                    LabeledContent("Status") {
                        switch app.parakeetState {
                        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .downloading: ProgressView().controlSize(.small)
                        case .failed(let why): Button("Retry") { Speech.downloadParakeet() }.help(why)
                        default: Button("Download") { Speech.downloadParakeet() }
                        }
                    }
                }
            }
            Section("Anthropic") {
                SecureField("API key", text: key(.anthropic))
                TextField("Model", text: $anthropicModel)
                Link("Get an API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            }
            Section("Dictation cleanup") {
                Picker("Cleaned up by", selection: $cleanup) {
                    ForEach(CleanupProvider.allCases) { Text($0.label).tag($0.rawValue) }
                }
                SecureField("Groq API key", text: key(.groq))
                SecureField("Cerebras API key", text: key(.cerebras))
                Text("Now using: \(CleanupProvider.resolved.label)").font(.caption).foregroundStyle(.secondary)
            }
            Section("Commands (routing, targets, safety)") {
                Picker("Decided by", selection: $decider) {
                    Text("Automatic (Jev, then Claude, then on-device)").tag("auto")
                    Text("Claude").tag("claude")
                    Text("Jev").tag("jev")
                    Text("On-device").tag("local")
                }
                SecureField("Jev / TypeSafe API key", text: key(.jev))
                TextField("Jev endpoint", text: $jevEndpoint)
            }
            Section("Writing (rewrites, answers, multi-step plans)") {
                Picker("Written by", selection: $provider) {
                    Text("Anthropic (Claude)").tag("anthropic")
                    Text("Groq").tag("groq")
                    Text("Cerebras").tag("cerebras")
                    Text("Local / OpenAI-compatible").tag("openai")
                    Text("Apple on-device").tag("apple")
                }

                if provider == "openai" || cleanup == "openai" {
                    TextField("Base URL", text: $openAIBase)
                    TextField("Model", text: $openAIModel)
                    SecureField("API key (optional)", text: key(.openai))
                }
            }
            Section {
                Text(String(format: "Estimated API spend so far: $%.4f (%d Jev calls)", UsageMeter.estimatedDollars, UsageMeter.jevCalls))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionsTab: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            Section {
                row("Accessibility", ok: controller.accessibilityGranted,
                    why: "Hotkeys, pasting text, reading and clicking on-screen controls") { controller.requestAccessibility() }
                row("Microphone", ok: controller.micGranted, why: "Hearing you. Speech is transcribed on this Mac.") { controller.requestMicrophone() }
                row("Speech model", ok: controller.speechReady, why: Speech.engineName, action: nil)
            }
            Section {
                Text("Rebuilt the app and permissions stopped working? Remove OpenNotch from System Settings › Privacy & Security › Accessibility and add it again. Ad-hoc signed builds get a new identity each build.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ name: String, ok: Bool, why: String, action: (() -> Void)?) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(name)
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok, let action { Button("Grant…", action: action) }
        }
    }
}

private struct UpdatesSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section("Updates") {
            if updater.isAvailable {
                Toggle("Check for updates daily", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                Toggle("Download and install automatically", isOn: Binding(get: { updater.automaticallyInstalls }, set: { updater.automaticallyInstalls = $0 }))
                Button("Check Now") { updater.checkForUpdates() }
            } else {
                Text("Development build: updates are off.").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProTab: View {
    @ObservedObject private var pro = Pro.shared
    @State private var license = Pro.licenseKey ?? ""

    var body: some View {
        Form {
            Section("\(Brand.name) Pro") {
                LabeledContent("Status") {
                    switch pro.status {
                    case .active: Label("Active", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    case .checking: ProgressView().controlSize(.small)
                    case .problem(let message): Text(message).foregroundStyle(.red)
                    case .inactive: Text("Not active").foregroundStyle(.secondary)
                    }
                }
                Text("Claude-powered cleanup and commands with no API key. $9.99/month or $79.99/year, 7 days free.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("License") {
                TextField("License key", text: $license)
                HStack {
                    Button("Activate") { Task { await pro.activate(license) } }
                        .disabled(license.trimmingCharacters(in: .whitespaces).isEmpty)
                    if Pro.licenseKey != nil { Button("Remove from this Mac", role: .destructive) { pro.signOut(); license = "" } }
                }
            }
            Section {
                Button("Start free trial (monthly)") { pro.openCheckout(yearly: false) }
                Button("Buy yearly ($79.99)") { pro.openCheckout(yearly: true) }
                Button("Manage subscription…") { pro.openManage() }
            }
        }
        .formStyle(.grouped)
    }
}
