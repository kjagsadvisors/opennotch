import AppKit

/// Opening OpenNotch straight from the disk image (or from Downloads) installs it: it copies itself
/// into Applications, ejects the disk image and reopens from there. macOS never runs anything when
/// an app is dragged into Applications, so this is what makes install a single double-click.
enum Installer {
    /// True when a copy in Applications is starting and this one should quit.
    @MainActor
    static func moveToApplicationsIfNeeded() -> Bool {
        let source = Bundle.main.bundleURL
        let path = source.path
        let home = NSHomeDirectory()
        guard path.hasSuffix(".app"),
              !path.hasPrefix("/Applications/"), !path.hasPrefix(home + "/Applications/") else { return false }
        let diskImage = path.hasPrefix("/Volumes/") ? volumeRoot(of: path) : nil
        let downloaded = path.hasPrefix(home + "/Downloads/") || path.contains("/AppTranslocation/")
        // Development builds run from wherever they were built.
        guard diskImage != nil || downloaded else { return false }

        let fm = FileManager.default
        let applications = fm.isWritableFile(atPath: "/Applications") ? "/Applications" : home + "/Applications"
        try? fm.createDirectory(atPath: applications, withIntermediateDirectories: true)
        let dest = URL(fileURLWithPath: applications).appendingPathComponent(source.lastPathComponent)
        do {
            if fm.fileExists(atPath: dest.path) {
                // An older copy: quit it if it's running, then replace it.
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                where app.bundleURL?.standardizedFileURL == dest.standardizedFileURL {
                    app.forceTerminate()
                }
                try fm.trashItem(at: dest, resultingItemURL: nil)
            }
            try fm.copyItem(at: source, to: dest)
        } catch {
            debugLog("install: \(error)")
            return false
        }
        // The person already opened this download once; don't make macOS ask them again.
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])

        // Reopen from Applications once this process is gone, then eject the disk image.
        var script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$1\""
        if let diskImage { script += "; sleep 1; /usr/bin/hdiutil detach \"$2\" -quiet" }
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", script, "sh", dest.path, diskImage ?? ""]
        try? relaunch.run()
        return true
    }

    /// "/Volumes/OpenNotch/OpenNotch.app" -> "/Volumes/OpenNotch".
    private static func volumeRoot(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count >= 2 ? "/" + parts[0...1].joined(separator: "/") : nil
    }

    private static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
