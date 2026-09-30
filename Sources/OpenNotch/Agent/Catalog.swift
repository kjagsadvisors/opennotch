import AppKit
import CoreGraphics

/// What a spoken command is for. Jev picks one of these; each has a deterministic executor.
enum Intent: String, CaseIterable {
    case openApp = "open_app"
    case click
    case menu
    case shortcut
    case type
    case rewrite
    case searchWeb = "search_web"
    case openURL = "open_url"
    case system
    case ask
    case multiStep = "multi_step"
    case fillForm = "fill_form"
    case dictation

    var description: String {
        switch self {
        case .openApp: return "Open, launch, switch to or bring up an application"
        case .click: return "Click, press, select, toggle or focus a specific visible button, link, tab, checkbox or field in the current window"
        case .menu: return "Run a command from the current app's menu bar, like File > Export or View > Show Sidebar"
        case .shortcut: return "A common editing or navigation action: undo, copy, paste, select all, save, new tab, close tab, reload, find, scroll, go back, press enter"
        case .type: return "Type out specific literal text the user dictates, e.g. 'type hello world'"
        case .rewrite: return "Transform the currently selected text: rewrite, rephrase, fix grammar, translate, shorten, summarize, change tone"
        case .searchWeb: return "Search the web or look something up online"
        case .openURL: return "Go to a specific website or web address"
        case .system: return "Change a system setting or do a system action: volume, mute, dark mode, lock screen, sleep display, screenshot, Mission Control"
        case .ask: return "A question to answer or explain in words, with no action taken on the computer"
        case .multiStep: return "A task that needs several steps or more than one app, e.g. open Safari and go to github.com"
        case .fillForm: return "Fill in the form on screen using text the user copied (like a resume) or details they give"
        case .dictation: return "Not a command at all: the user is just saying text that should be typed"
        }
    }

    static var question: Question {
        .choice("What does the user want done with this spoken command?", allCases.map { ($0.rawValue, $0.description) })
    }
}

struct Shortcut {
    let id: String
    let description: String
    let key: CGKeyCode
    let flags: CGEventFlags

    func run() { Keys.press(key, flags) }

    static let all: [Shortcut] = [
        .init(id: "undo", description: "Undo", key: 6, flags: .maskCommand),
        .init(id: "redo", description: "Redo", key: 6, flags: [.maskCommand, .maskShift]),
        .init(id: "copy", description: "Copy", key: 8, flags: .maskCommand),
        .init(id: "cut", description: "Cut", key: 7, flags: .maskCommand),
        .init(id: "paste", description: "Paste", key: 9, flags: .maskCommand),
        .init(id: "select_all", description: "Select all", key: 0, flags: .maskCommand),
        .init(id: "save", description: "Save", key: 1, flags: .maskCommand),
        .init(id: "find", description: "Find / search in page or document", key: 3, flags: .maskCommand),
        .init(id: "new_tab", description: "Open a new tab", key: 17, flags: .maskCommand),
        .init(id: "close_tab", description: "Close the current tab or window", key: 13, flags: .maskCommand),
        .init(id: "reopen_tab", description: "Reopen the last closed tab", key: 17, flags: [.maskCommand, .maskShift]),
        .init(id: "new_window", description: "Open a new window or new document", key: 45, flags: .maskCommand),
        .init(id: "next_tab", description: "Go to the next tab", key: 48, flags: .maskControl),
        .init(id: "previous_tab", description: "Go to the previous tab", key: 48, flags: [.maskControl, .maskShift]),
        .init(id: "reload", description: "Reload or refresh the page", key: 15, flags: .maskCommand),
        .init(id: "back", description: "Go back", key: 33, flags: .maskCommand),
        .init(id: "forward", description: "Go forward", key: 30, flags: .maskCommand),
        .init(id: "address_bar", description: "Focus the browser address bar", key: 37, flags: .maskCommand),
        .init(id: "scroll_down", description: "Scroll down a page", key: 121, flags: []),
        .init(id: "scroll_up", description: "Scroll up a page", key: 116, flags: []),
        .init(id: "top", description: "Jump to the top", key: 126, flags: .maskCommand),
        .init(id: "bottom", description: "Jump to the bottom", key: 125, flags: .maskCommand),
        .init(id: "enter", description: "Press Return / Enter / submit the current line", key: 36, flags: []),
        .init(id: "escape", description: "Press Escape / dismiss", key: 53, flags: []),
        .init(id: "tab_key", description: "Press Tab to move to the next field", key: 48, flags: []),
        .init(id: "minimize", description: "Minimize the window", key: 46, flags: .maskCommand),
        .init(id: "fullscreen", description: "Toggle full screen", key: 3, flags: [.maskCommand, .maskControl]),
        .init(id: "zoom_in", description: "Zoom in / make text bigger", key: 24, flags: .maskCommand),
        .init(id: "zoom_out", description: "Zoom out / make text smaller", key: 27, flags: .maskCommand),
        .init(id: "actual_size", description: "Reset zoom to actual size", key: 29, flags: .maskCommand),
        .init(id: "bold", description: "Make selected text bold", key: 11, flags: .maskCommand),
        .init(id: "italic", description: "Make selected text italic", key: 34, flags: .maskCommand),
        .init(id: "underline", description: "Underline selected text", key: 32, flags: .maskCommand),
        .init(id: "hide_app", description: "Hide the current app", key: 4, flags: .maskCommand),
        .init(id: "quit_app", description: "Quit the current app", key: 12, flags: .maskCommand),
        .init(id: "spotlight", description: "Open Spotlight search", key: 49, flags: .maskCommand),
    ]

    static func find(_ id: String) -> Shortcut? { all.first { $0.id == id } }

    static var question: Question {
        .choice("Which keyboard action matches what the user asked for? Pick none if none fits.",
                all.map { ($0.id, $0.description) } + [("none", "None of these")])
    }
}

enum SystemAction: String, CaseIterable {
    case volumeUp = "volume_up", volumeDown = "volume_down", mute = "toggle_mute"
    case darkMode = "toggle_dark_mode", lockScreen = "lock_screen", sleepDisplay = "sleep_display"
    case screenshot, screenshotRegion = "screenshot_region", missionControl = "mission_control"
    case playMusic = "play_music", pauseMusic = "pause_music", nextTrack = "next_track", previousTrack = "previous_track"

    var description: String {
        switch self {
        case .playMusic: return "Play music, or resume whatever was playing"
        case .pauseMusic: return "Pause the music or audio that's playing"
        case .nextTrack: return "Skip to the next song"
        case .previousTrack: return "Go back to the previous song"
        case .volumeUp: return "Turn the volume up"
        case .volumeDown: return "Turn the volume down"
        case .mute: return "Mute or unmute sound"
        case .darkMode: return "Switch between dark mode and light mode"
        case .lockScreen: return "Lock the screen"
        case .sleepDisplay: return "Turn off / sleep the display"
        case .screenshot: return "Take a screenshot of the whole screen"
        case .screenshotRegion: return "Take a screenshot of part of the screen"
        case .missionControl: return "Show Mission Control / all windows"
        }
    }

    var summary: String { description }

    /// What the assistant says when it's done, if the action doesn't report something better.
    var spoken: String? {
        switch self {
        case .volumeUp: return "Turning it up."
        case .volumeDown: return "Turning it down."
        case .darkMode: return "Switching the look."
        case .pauseMusic: return "Paused."
        case .screenshot, .screenshotRegion: return "Got it."
        default: return nil
        }
    }

    /// Runs the action; media actions return what's now playing ("Playing Purple Rain by Prince").
    func run() throws -> String? {
        switch self {
        case .playMusic: return try MediaPlayer.play()
        case .pauseMusic: try MediaPlayer.tell("pause"); return nil
        case .nextTrack: return try MediaPlayer.nowPlaying(after: "next track")
        case .previousTrack: return try MediaPlayer.nowPlaying(after: "previous track")
        case .volumeUp: try osa("set volume output volume ((output volume of (get volume settings)) + 12)")
        case .volumeDown: try osa("set volume output volume ((output volume of (get volume settings)) - 12)")
        case .mute: try osa("set volume output muted not (output muted of (get volume settings))")
        case .darkMode: try osa("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        case .lockScreen: Keys.press(12, [.maskCommand, .maskControl])
        case .sleepDisplay:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["displaysleepnow"]
            try p.run()
        case .screenshot: Keys.press(20, [.maskCommand, .maskShift])
        case .screenshotRegion: Keys.press(21, [.maskCommand, .maskShift])
        case .missionControl: Keys.press(126, .maskControl)
        }
        return nil
    }

    private func osa(_ source: String) throws {
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { throw NSError(domain: "AppleScript", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(err[NSAppleScript.errorMessage] ?? err)"]) }
    }

    static var question: Question {
        .choice("Which system action matches what the user asked for? Pick none if none fits.",
                allCases.map { ($0.rawValue, $0.description) } + [("none", "None of these")])
    }
}

/// Spotify if it's open, otherwise Apple Music. Asks the player what's on so the assistant can say it.
enum MediaPlayer {
    static var app: String {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" } ? "Spotify" : "Music"
    }

    static func play() throws -> String? {
        let start = app == "Music"
            ? "if player state is paused then\n play\n else if player state is not playing then\n set shuffle enabled to true\n play library playlist 1\n end if"
            : "play"
        return try nowPlaying(after: start)
    }

    static func tell(_ command: String) throws {
        _ = try osa("tell application \"\(app)\" to \(command)")
    }

    static func nowPlaying(after command: String) throws -> String? {
        let out = try osa("""
        tell application "\(app)"
            \(command)
            delay 0.7
            if player state is playing then return (name of current track) & tab & (artist of current track)
        end tell
        return ""
        """)
        let parts = out.split(separator: "\t", maxSplits: 1).map(String.init)
        guard let song = parts.first, !song.isEmpty else { return nil }
        return parts.count > 1 && !parts[1].isEmpty ? "Playing \(song) by \(parts[1])." : "Playing \(song)."
    }

    private static func osa(_ source: String) throws -> String {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { throw NSError(domain: "AppleScript", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(err[NSAppleScript.errorMessage] ?? err)"]) }
        return result?.stringValue ?? ""
    }
}

/// Installed applications by display name.
final class AppIndex {
    static let shared = AppIndex()
    private(set) var apps: [String: URL] = [:]

    func refresh() {
        let fm = FileManager.default
        var found: [String: URL] = [:]
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     NSHomeDirectory() + "/Applications"]
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items {
                let path = root + "/" + item
                if item.hasSuffix(".app") {
                    found[String(item.dropLast(4))] = URL(fileURLWithPath: path)
                } else if let sub = try? fm.contentsOfDirectory(atPath: path) {
                    // One level of folders, e.g. /Applications/Microsoft Office/…
                    for s in sub where s.hasSuffix(".app") {
                        found[String(s.dropLast(4))] = URL(fileURLWithPath: path + "/" + s)
                    }
                }
            }
        }
        found["Finder"] = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let name = app.localizedName, let url = app.bundleURL { found[name] = url }
        }
        apps = found
    }

    func question(for said: String, limit: Int) -> Question {
        let names = OptionRanker.top(apps.keys.sorted(), label: { $0 }, query: said, limit: limit)
        return .choice("Which application does the user want?", names.map { ($0, $0) })
    }

    /// Starts an app in the background so a command that's still being spoken finishes instantly.
    func prelaunch(_ name: String) {
        guard let url = apps[name],
              !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL == url }) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    func open(_ name: String) async throws {
        guard let url = apps[name] else { throw NSError(domain: "OpenNotch", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(name) isn't installed"]) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
