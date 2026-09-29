import AppKit
import CoreGraphics

enum Keys {
    /// Posts a key press to whichever app has keyboard focus.
    static func press(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Types a string as keyboard input, in small chunks (without using the clipboard).
    static func type(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            i += 20
        }
    }
}

/// Puts text at the cursor by pasting, then restores whatever was on the clipboard.
/// Pasting is instant for any length and works in every app that accepts ⌘V.
enum TextInserter {
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Tells clipboard managers not to record this.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
        let ours = pb.changeCount

        Keys.press(9, .maskCommand)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // If something else wrote to the clipboard meanwhile, leave it alone.
            guard pb.changeCount == ours else { return }
            pb.clearContents()
            let items = saved.map { dict -> NSPasteboardItem in
                let it = NSPasteboardItem()
                for (t, data) in dict { it.setData(data, forType: t) }
                return it
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }
}
