import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// Where accounts live (Supabase Auth). The publishable key only identifies the project; it's
/// meant to ship in apps.
enum AccountConfig {
    static let supabaseURL = URL(string: "https://nclsnaetdkgtimtvxvho.supabase.co")!
    static let publishableKey = "sb_publishable_zArUVkWF7INkpor1v6i6Aw_D9xDFbhv"
    static let callbackScheme = "opennotch"
    static let redirect = "opennotch://auth-callback"
    /// Returns the license key an account bought, so Pro turns on without pasting anything.
    static let accountEndpoint = URL(string: "https://opennotch.ai/api/v1/account")!
    static let terms = URL(string: "https://opennotch.ai/terms")!
    static let privacy = URL(string: "https://opennotch.ai/privacy")!
}

/// OpenNotch accounts: Apple, Google, GitHub, or an emailed link/code. Required once, near the end
/// of onboarding. After that the app keeps working offline: the refresh token lives in the Keychain
/// and access tokens are fetched only when the server needs one.
@MainActor
final class Account: NSObject, ObservableObject {
    static let shared = Account()

    enum Provider: String, CaseIterable, Identifiable {
        case apple, google, github
        var id: String { rawValue }
        var title: String {
            switch self {
            case .apple: return "Continue with Apple"
            case .google: return "Continue with Google"
            case .github: return "Continue with GitHub"
            }
        }
    }

    enum Status: Equatable {
        case signedOut
        case working
        case emailSent(String)
        case signedIn(String)
        case problem(String)
    }

    @Published private(set) var status: Status

    var email: String? { if case .signedIn(let e) = status { return e }; return nil }

    /// Readable from any thread; no Keychain access on the hot path.
    nonisolated static var isSignedIn: Bool { email != nil }
    nonisolated static var email: String? { UserDefaults.standard.string(forKey: "accountEmail") }
    nonisolated static var userID: String? { UserDefaults.standard.string(forKey: "accountID") }

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var webSession: ASWebAuthenticationSession?

    private override init() {
        status = Self.email.map(Status.signedIn) ?? .signedOut
    }

    // MARK: - Signing in

    func signIn(with provider: Provider) {
        let pkce = PKCE()
        var c = URLComponents(url: AccountConfig.supabaseURL.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_to", value: AccountConfig.redirect),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        status = .working
        let session = ASWebAuthenticationSession(url: c.url!, callback: .customScheme(AccountConfig.callbackScheme)) { url, error in
            Task { @MainActor in
                if let url {
                    await self.complete(callback: url, verifier: pkce.verifier)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    self.status = .signedOut
                } else {
                    self.status = .problem(error?.localizedDescription ?? "Sign-in didn't finish. Try again.")
                }
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        webSession = session
        session.start()
    }

    /// Emails a sign-in link that also carries a 6-digit code, for people who'd rather type it.
    func sendEmail(to rawEmail: String) async {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.contains(".") else { return status = .problem("Enter your email address.") }
        let pkce = PKCE()
        UserDefaults.standard.set(pkce.verifier, forKey: "accountPKCE")
        status = .working
        do {
            _ = try await auth("otp", query: ["redirect_to": AccountConfig.redirect], body: [
                "email": email, "create_user": true,
                "code_challenge": pkce.challenge, "code_challenge_method": "s256",
            ])
            status = .emailSent(email)
        } catch {
            status = .problem(error.localizedDescription)
        }
    }

    func verify(code: String, email: String) async {
        let token = code.filter(\.isNumber)
        guard token.count >= 6 else { return }
        status = .working
        do {
            store(try await auth("verify", body: ["type": "email", "email": email, "token": token]))
            await linkPro()
        } catch {
            status = .problem("That code didn't work. Check the newest email, or send a new one.")
        }
    }

    /// opennotch://auth-callback?code=… from an OAuth redirect or a clicked email link.
    func handle(_ url: URL) {
        guard url.host == "auth-callback" else { return }
        guard let verifier = UserDefaults.standard.string(forKey: "accountPKCE") else { return }
        Task { await complete(callback: url, verifier: verifier) }
    }

    private func complete(callback url: URL, verifier: String) async {
        let params = Self.parameters(url)
        guard let code = params["code"] else {
            status = .problem(params["error_description"]?.replacingOccurrences(of: "+", with: " ") ?? "Sign-in was cancelled.")
            return
        }
        status = .working
        do {
            store(try await auth("token", query: ["grant_type": "pkce"], body: ["auth_code": code, "code_verifier": verifier]))
            UserDefaults.standard.removeObject(forKey: "accountPKCE")
            await linkPro()
        } catch {
            status = .problem(error.localizedDescription)
        }
    }

    func signOut() {
        if let token = accessToken {
            Task { _ = try? await auth("logout", query: ["scope": "local"], body: [:], bearer: token) }
        }
        Secrets.set(.accountRefresh, "")
        for k in ["accountEmail", "accountID", "accountPKCE"] { UserDefaults.standard.removeObject(forKey: k) }
        accessToken = nil
        status = .signedOut
    }

    // MARK: - Tokens

    /// A current access token, refreshed when it's within a minute of expiring.
    func validAccessToken() async throws -> String {
        if let accessToken, accessExpiry.timeIntervalSinceNow > 60 { return accessToken }
        guard let refresh = Secrets.get(.accountRefresh) else { throw AccountError.message("Sign in first.") }
        store(try await auth("token", query: ["grant_type": "refresh_token"], body: ["refresh_token": refresh]))
        guard let accessToken else { throw AccountError.message("Sign in again.") }
        return accessToken
    }

    private func store(_ session: [String: Any]) {
        guard let access = session["access_token"] as? String, let refresh = session["refresh_token"] as? String else { return }
        accessToken = access
        accessExpiry = Date().addingTimeInterval(session["expires_in"] as? TimeInterval ?? 3600)
        Secrets.set(.accountRefresh, refresh)
        if let user = session["user"] as? [String: Any] {
            if let email = user["email"] as? String { UserDefaults.standard.set(email, forKey: "accountEmail") }
            if let id = user["id"] as? String { UserDefaults.standard.set(id, forKey: "accountID") }
        }
        if let email = Self.email { status = .signedIn(email) }
    }

    // MARK: - Pro

    /// Pro follows the account: if this email bought Pro, turn it on here without a key.
    func linkPro() async {
        guard Self.isSignedIn, Pro.shared.status != .active, let token = try? await validAccessToken() else { return }
        var req = URLRequest(url: AccountConfig.accountEndpoint, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["licenseKey"] as? String, !key.isEmpty else { return }
        await Pro.shared.activate(key)
        if Pro.shared.status == .active { Pro.shared.onActivated?() }
    }

    // MARK: - Supabase Auth

    private enum AccountError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    private func auth(_ path: String, query: [String: String] = [:], body: [String: Any], bearer: String? = nil) async throws -> [String: Any] {
        var c = URLComponents(url: AccountConfig.supabaseURL.appendingPathComponent("auth/v1/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AccountConfig.publishableKey, forHTTPHeaderField: "apikey")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let message = obj["msg"] as? String ?? obj["error_description"] as? String ?? obj["message"] as? String
            debugLog("auth \(path) \(code): \(String(data: data, encoding: .utf8) ?? "")")
            throw AccountError.message(message ?? "Sign-in failed (\(code)). Try again.")
        }
        return obj
    }

    /// Query items and fragment items together (errors can arrive in either).
    private static func parameters(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        for item in c?.queryItems ?? [] { out[item.name] = item.value }
        if let fragment = c?.fragment, let f = URLComponents(string: "?" + fragment) {
            for item in f.queryItems ?? [] { out[item.name] = item.value }
        }
        return out
    }
}

extension Account: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor() }
    }
}

/// Proof Key for Code Exchange: the app proves it started the flow it's finishing.
private struct PKCE {
    let verifier: String
    let challenge: String

    init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Self.base64url(Data(bytes))
        challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
