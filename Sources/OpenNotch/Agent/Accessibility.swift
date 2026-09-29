import AppKit
import ApplicationServices

/// Something on screen that a command can act on, found through the Accessibility tree.
struct UITarget {
    enum Kind { case press, focus }
    let label: String
    let element: AXUIElement
    let kind: Kind
}

/// Snapshot of the frontmost app, taken while the user is still talking so it costs no latency.
struct ScreenContext {
    let app: NSRunningApplication?
    let windowTitle: String?
    let elements: [UITarget]
    let menuItems: [UITarget]
    let hasSelection: Bool

    var appName: String { app?.localizedName ?? "unknown app" }

    static func capture(app: NSRunningApplication?) -> ScreenContext {
        guard let app, AX.isTrusted else {
            return ScreenContext(app: app, windowTitle: nil, elements: [], menuItems: [], hasSelection: false)
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AX.enableElectronAccessibility(root)
        let window: AXUIElement? = AX.element(root, kAXFocusedWindowAttribute) ?? AX.element(root, kAXMainWindowAttribute)
        let title: String? = window.flatMap { AX.string($0, kAXTitleAttribute) }
        return ScreenContext(
            app: app,
            windowTitle: title,
            elements: window.map { AX.actionableElements(in: $0) } ?? [],
            menuItems: AX.menuItems(of: root),
            hasSelection: !(AX.selectedText() ?? "").isEmpty
        )
    }
}

enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        (value(el, attr) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (value(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func isEnabled(_ el: AXUIElement) -> Bool {
        (value(el, kAXEnabledAttribute) as? Bool) ?? true
    }

    /// Electron apps (Slack, VS Code, Notion…) only expose their UI tree when asked.
    static func enableElectronAccessibility(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    @discardableResult
    static func perform(_ target: UITarget) -> Bool {
        switch target.kind {
        case .press:
            return AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success
        case .focus:
            return AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        }
    }

    static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        guard let focused = element(system, kAXFocusedUIElementAttribute) else { return nil }
        return value(focused, kAXSelectedTextAttribute) as? String
    }

    private static let pressRoles: [String: String] = [
        "AXButton": "button", "AXLink": "link", "AXCheckBox": "checkbox", "AXRadioButton": "tab/option",
        "AXPopUpButton": "popup menu", "AXMenuButton": "menu button", "AXDisclosureTriangle": "disclosure",
        "AXTab": "tab", "AXCell": "cell", "AXRow": "row", "AXMenuItem": "menu item", "AXImage": "image",
        "AXStaticText": "text", "AXSwitch": "switch", "AXSegment": "segment",
    ]
    private static let focusRoles: [String: String] = [
        "AXTextField": "text field", "AXSearchField": "search field", "AXTextArea": "text area", "AXComboBox": "combo box",
    ]

    /// Breadth-first walk of a window collecting things you could click or type into.
    /// Bounded by node count and time so a giant web page can't stall the command.
    static func actionableElements(in window: AXUIElement, maxNodes: Int = 4000, budget: TimeInterval = 0.4) -> [UITarget] {
        let deadline = Date().addingTimeInterval(budget)
        var queue: [AXUIElement] = [window]
        var head = 0
        var out: [UITarget] = []
        var seen: [String: Int] = [:]

        while head < queue.count, head < maxNodes, Date() < deadline {
            let el = queue[head]
            head += 1
            queue.append(contentsOf: children(el))

            guard let role = string(el, kAXRoleAttribute) else { continue }
            let kind: UITarget.Kind
            let roleName: String
            if let r = focusRoles[role] {
                kind = .focus
                roleName = r
            } else if let r = pressRoles[role], actions(el).contains(kAXPressAction as String) {
                kind = .press
                roleName = r
            } else {
                continue
            }
            guard isEnabled(el), let name = label(for: el) else { continue }

            var text = "\(roleName) \"\(name)\""
            if let n = seen[text] {
                seen[text] = n + 1
                text += " #\(n + 1)"
            } else {
                seen[text] = 1
            }
            out.append(UITarget(label: text, element: el, kind: kind))
        }
        return out
    }

    static func label(for el: AXUIElement) -> String? {
        let candidates = [
            string(el, kAXTitleAttribute),
            string(el, kAXDescriptionAttribute),
            value(el, kAXValueAttribute) as? String,
            string(el, kAXPlaceholderValueAttribute),
            string(el, kAXHelpAttribute),
        ]
        guard var s = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) else { return nil }
        s = s.replacingOccurrences(of: "\n", with: " ")
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }

    /// Every enabled menu command, labeled by path ("File › New Tab").
    static func menuItems(of app: AXUIElement) -> [UITarget] {
        guard let bar = element(app, kAXMenuBarAttribute) else { return [] }
        var out: [UITarget] = []
        // Skip the Apple menu; its commands are system-wide, not the app's.
        for top in children(bar).dropFirst() {
            guard let title = string(top, kAXTitleAttribute) else { continue }
            for menu in children(top) { collectMenu(menu, path: title, depth: 0, into: &out) }
        }
        return out
    }

    private static func collectMenu(_ menu: AXUIElement, path: String, depth: Int, into out: inout [UITarget]) {
        guard depth < 3, out.count < 1500 else { return }
        for item in children(menu) {
            guard let title = string(item, kAXTitleAttribute), isEnabled(item) else { continue }
            let p = "\(path) › \(title)"
            let sub = children(item)
            if sub.isEmpty {
                out.append(UITarget(label: p, element: item, kind: .press))
            } else {
                for s in sub { collectMenu(s, path: p, depth: depth + 1, into: &out) }
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
