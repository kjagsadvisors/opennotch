import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if DevCLI.handles(CommandLine.arguments) { return }
        OpenNotchApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// opennotch://activate?key=OPENNOTCH-… activates Pro in one click (from the thank-you page or email).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "opennotch" && url.host == "auth-callback" {
            MainActor.assumeIsolated { Account.shared.handle(url) }
        }
        for url in urls where url.scheme == "opennotch" && url.host == "activate" {
            guard let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "key" })?.value else { continue }
            Task { @MainActor in await Pro.shared.activate(key) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppController.shared.bootstrap()
            _ = Updater.shared
            Task {
                await Pro.shared.refresh()
                await Account.shared.linkPro()
            }
            Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in
                Task { @MainActor in await Pro.shared.refresh() }
            }
        }
    }
}

struct OpenNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("OpenNotch", systemImage: "waveform") {
            MenuContent(controller: AppController.shared)
        }
        Settings {
            SettingsView(controller: AppController.shared)
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var pro = Pro.shared
    @ObservedObject private var account = Account.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let email = account.email {
            Text("Signed in as \(email)")
        } else {
            Button("Sign In…") { Onboarding.shared.showAccount() }
        }
        if pro.status != .active {
            Button("Upgrade to Pro — 7 days free…") { pro.openCheckout(yearly: true) }
        }
        Divider()
        Text(controller.statusLine)
        Text("Speech: \(Speech.engineName)")
        Text("Decisions: \(Deciders.current().name)")
        Text(String(format: "API spend so far: $%.4f", UsageMeter.estimatedDollars))
        Divider()
        if !controller.accessibilityGranted {
            Button("Grant Accessibility…") { controller.requestAccessibility() }
        }
        if !controller.micGranted {
            Button("Grant Microphone…") { controller.requestMicrophone() }
        }
        if Updater.shared.isAvailable {
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
        }
        Button("Welcome Tour…") { Onboarding.shared.start() }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit OpenNotch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
