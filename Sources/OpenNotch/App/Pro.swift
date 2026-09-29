import AppKit
import Foundation

/// Endpoints for OpenNotch Pro. Checkout and portal links go through opennotch.ai redirects, so
/// changing prices or plans on Polar never needs an app update.
enum ProConfig {
    /// Settings → General → Organization ID on polar.sh (not a secret).
    static let polarOrganizationID = "75661d8b-d7e6-4180-964c-306197322d32"
    static let monthlyCheckout = URL(string: "https://opennotch.ai/pro/monthly")!
    static let yearlyCheckout = URL(string: "https://opennotch.ai/pro/yearly")!
    static let manage = URL(string: "https://opennotch.ai/pro/manage")!
    /// Claude proxy for Pro users: checks the license, then forwards to Claude Haiku.
    static let proxyEndpoint = URL(string: "https://opennotch.ai/api/v1/messages")!

    static var isConfigured: Bool { !polarOrganizationID.hasPrefix("REPLACE") }
}

/// OpenNotch Pro ($9.99/month or $79.99/year, 7-day free trial, sold through Polar).
/// Pro means no API key: cleanup, commands and writing run on Claude through our server.
/// The open-source build keeps working without it (your own key, or fully on-device).
@MainActor
final class Pro: ObservableObject {
    static let shared = Pro()

    enum Status: Equatable {
        case inactive
        case checking
        case active
        case problem(String)
    }

    @Published private(set) var status: Status

    /// Readable from any thread (model selection happens off the main actor).
    nonisolated static var isActive: Bool { UserDefaults.standard.bool(forKey: "proActive") }

    nonisolated static var licenseKey: String? { Secrets.get(.proLicense) }
    nonisolated static var activationID: String? { Secrets.get(.proActivation) }

    private init() {
        status = Self.isActive ? .active : .inactive
    }

    /// Registers this Mac against the license (Polar enforces the device limit), then validates.
    func activate(_ rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard ProConfig.isConfigured else { return setProblem("Pro isn't set up in this build yet.") }
        status = .checking
        do {
            let label = Host.current().localizedName ?? "Mac"
            let activation = try await polar("activate", ["key": key, "organization_id": ProConfig.polarOrganizationID, "label": label])
            Secrets.set(.proLicense, key)
            if let id = activation["id"] as? String { Secrets.set(.proActivation, id) }
            await refresh()
        } catch PolarError.status(let code, _) where code == 403 || code == 422 {
            // Keys without a device limit can't be "activated"; validating is enough.
            Secrets.set(.proLicense, key)
            Secrets.set(.proActivation, "")
            await refresh()
        } catch {
            setProblem(error.localizedDescription)
        }
    }

    /// Re-checks the license (at launch and daily). A lapsed or cancelled subscription turns Pro off.
    func refresh() async {
        guard ProConfig.isConfigured, let key = Self.licenseKey else { return setActive(false) }
        var body: [String: Any] = ["key": key, "organization_id": ProConfig.polarOrganizationID]
        if let activation = Self.activationID, !activation.isEmpty { body["activation_id"] = activation }
        do {
            let result = try await polar("validate", body)
            let granted = result["status"] as? String == "granted"
            setActive(granted)
            if !granted { setProblem("Your Pro subscription isn't active.") }
        } catch PolarError.status(let code, _) where code == 404 {
            setActive(false)
            setProblem("That license key wasn't found.")
        } catch {
            // Offline: keep the last known state rather than cutting a paying user off.
            debugLog("pro refresh: \(error)")
            status = Self.isActive ? .active : .inactive
        }
    }

    func signOut() {
        Secrets.set(.proLicense, "")
        Secrets.set(.proActivation, "")
        setActive(false)
    }

    func openCheckout(yearly: Bool) {
        NSWorkspace.shared.open(yearly ? ProConfig.yearlyCheckout : ProConfig.monthlyCheckout)
        watchClipboardForLicense()
    }

    private var clipboardTimer: Timer?

    /// After checkout, the key arrives by email. For 45 minutes, a copied OPENNOTCH key is picked
    /// up and activated without pasting anywhere. Only that prefix is ever looked at.
    private func watchClipboardForLicense() {
        clipboardTimer?.invalidate()
        let until = Date().addingTimeInterval(45 * 60)
        var lastChange = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, Date() < until, self.status != .active else { return timer.invalidate() }
                let pb = NSPasteboard.general
                guard pb.changeCount != lastChange else { return }
                lastChange = pb.changeCount
                guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      text.uppercased().hasPrefix("OPENNOTCH"), text.count < 120 else { return }
                timer.invalidate()
                await self.activate(text)
                if self.status == .active { self.onActivated?() }
            }
        }
    }

    /// Lets the app celebrate in the notch when Pro turns on.
    var onActivated: (() -> Void)?
    func openManage() { NSWorkspace.shared.open(ProConfig.manage) }

    private func setActive(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "proActive")
        status = on ? .active : .inactive
    }

    private func setProblem(_ message: String) { status = .problem(message) }

    private enum PolarError: LocalizedError {
        case status(Int, String)
        var errorDescription: String? {
            if case .status(let code, let body) = self { return "License server returned \(code): \(body.prefix(160))" }
            return nil
        }
    }

    private func polar(_ action: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.polar.sh/v1/customer-portal/license-keys/\(action)")!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw PolarError.status(code, String(data: data, encoding: .utf8) ?? "") }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
