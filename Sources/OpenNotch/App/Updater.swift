import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

/// Auto-updates through Sparkle: checks the signed appcast once a day, downloads in the background,
/// and never installs without the user's say-so unless they opt in to automatic installs.
/// Every update must carry our EdDSA signature (SUPublicEDKey in Info.plist) and Apple notarization.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    #if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController?
    #endif

    /// False in dev builds without Sparkle, or before a release signing key is configured.
    let isAvailable: Bool

    private init() {
        #if canImport(Sparkle)
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        if key.isEmpty || key.hasPrefix("REPLACE") {
            controller = nil
            isAvailable = false
        } else {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            isAvailable = true
        }
        #else
        isAvailable = false
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        #endif
    }

    var automaticallyChecks: Bool {
        get {
            #if canImport(Sparkle)
            return controller?.updater.automaticallyChecksForUpdates ?? false
            #else
            return false
            #endif
        }
        set {
            #if canImport(Sparkle)
            controller?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
            #endif
        }
    }

    var automaticallyInstalls: Bool {
        get {
            #if canImport(Sparkle)
            return controller?.updater.automaticallyDownloadsUpdates ?? false
            #else
            return false
            #endif
        }
        set {
            #if canImport(Sparkle)
            controller?.updater.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
            #endif
        }
    }
}
