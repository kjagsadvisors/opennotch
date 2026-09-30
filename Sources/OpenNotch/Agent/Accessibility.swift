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
        AX.enableAccessibility(for: app)
        let window: AXUIElement? = AX.element(root, kAXFocusedWindowAttribute) ?? AX.element(root, kAXMainWindowAttribute)
        let title: String? = window.flatMap { AX.string($0, kAXTitleAttribute) }
        return ScreenContext(
            app: app,
            windowTitle: title,
            elements: window.map { AX.targets(in: $0) } ?? [],
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

    /// Chromium browsers and Electron apps (Chrome, Arc, Slack, VS Code, Notion…) only build the
    /// accessibility tree for their web content once an assistive app asks for it. Done when an app
    /// comes to the front, so the tree is ready by the time the user finishes talking.
    static func enableAccessibility(for app: NSRunningApplication) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if chromiumBrowsers.contains(app.bundleIdentifier ?? "") {
            AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// Presses (or focuses) the element. Web content that ignores the accessibility press gets a
    /// real mouse click at its center instead.
    @discardableResult
    static func perform(_ target: UITarget) -> Bool {
        switch target.kind {
        case .press:
            if AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success { return true }
            return click(target.element)
        case .focus:
            if AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success { return true }
            return click(target.element)
        }
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = value(el, kAXPositionAttribute), let s = value(el, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    static func click(_ el: AXUIElement) -> Bool {
        guard let f = frame(el) else { return false }
        let point = CGPoint(x: f.midX, y: f.midY)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        return true
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

    /// Everything you could click or type into in a window: the app's own controls, plus the
    /// visible links, buttons and fields of any web page in it.
    static func targets(in window: AXUIElement) -> [UITarget] {
        var seen: [String: Int] = [:]
        var webAreas: [AXUIElement] = []
        var out = actionableElements(in: window, seen: &seen, webAreas: &webAreas)
        debugLog("web areas: \(webAreas.count)")
        for area in webAreas.prefix(2) {
            out += webTargets(in: area, seen: &seen)
        }
        return out
    }

    /// Kept for callers that only want a window walk.
    static func actionableElements(in window: AXUIElement) -> [UITarget] { targets(in: window) }

    /// Breadth-first walk of the app's own controls. Web pages are handed to `webTargets` instead of
    /// walked node by node (a page can have thousands). Bounded by node count and time.
    private static func actionableElements(in window: AXUIElement, seen: inout [String: Int], webAreas: inout [AXUIElement],
                                           maxNodes: Int = 3000, budget: TimeInterval = 0.35) -> [UITarget] {
        let deadline = Date().addingTimeInterval(budget)
        var queue: [AXUIElement] = [window]
        var head = 0
        var out: [UITarget] = []

        while head < queue.count, head < maxNodes, Date() < deadline {
            let el = queue[head]
            head += 1
            guard let role = string(el, kAXRoleAttribute) else { continue }
            if role == "AXWebArea" {
                webAreas.append(el)
                continue
            }
            queue.append(contentsOf: children(el))
            if let target = target(el, role: role, seen: &seen) { out.append(target) }
        }
        return out
    }

    /// The visible links, buttons and fields in a web page, in one call: the search API that
    /// VoiceOver's rotor uses, implemented by Safari (WebKit) and Chromium.
    private static func webTargets(in area: AXUIElement, seen: inout [String: Int], limit: Int = 250) -> [UITarget] {
        let keys = ["AXLinkSearchKey", "AXButtonSearchKey", "AXTextFieldSearchKey", "AXCheckBoxSearchKey",
                    "AXRadioGroupSearchKey", "AXControlSearchKey"]
        let params: [String: Any] = [
            "AXSearchKey": keys, "AXVisibleOnly": true, "AXResultsLimit": limit, "AXDirection": "AXDirectionNext",
        ]
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(area, "AXUIElementsForSearchPredicate" as CFString,
                                                         params as CFDictionary, &result) == .success,
              let found = result as? [AXUIElement] else { debugLog("web search unavailable"); return [] }
        debugLog("web search found \(found.count)")
        return found.compactMap { el in
            guard let role = string(el, kAXRoleAttribute) else { return nil }
            return target(el, role: role, seen: &seen, web: true)
        }
    }

    private static func target(_ el: AXUIElement, role: String, seen: inout [String: Int], web: Bool = false) -> UITarget? {
        let kind: UITarget.Kind
        let roleName: String
        if let r = focusRoles[role] {
            kind = .focus
            roleName = r
        } else if let r = pressRoles[role], web || actions(el).contains(kAXPressAction as String) {
            kind = .press
            roleName = r
        } else if role == "AXRow" {
            // Sidebar and list rows (System Settings, Mail, Finder…) select on click, not on AXPress.
            kind = .press
            roleName = "row"
        } else if web {
            // Web controls with custom roles (e.g. a div acting as a button) still take a click.
            kind = .press
            roleName = "control"
        } else {
            return nil
        }
        guard isEnabled(el), let name = label(for: el) else { return nil }
        var text = "\(roleName) \"\(name)\""
        if let n = seen[text] {
            seen[text] = n + 1
            text += " #\(n + 1)"
        } else {
            seen[text] = 1
        }
        return UITarget(label: text, element: el, kind: kind)
    }

    static func label(for el: AXUIElement) -> String? {
        let candidates = [
            string(el, kAXTitleAttribute),
            string(el, kAXDescriptionAttribute),
            value(el, kAXValueAttribute) as? String,
            string(el, kAXPlaceholderValueAttribute),
            string(el, kAXHelpAttribute),
        ]
        guard var s = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty })
                ?? childText(el) else { return nil }
        s = s.replacingOccurrences(of: "\n", with: " ")
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }

    /// Links and buttons on web pages often keep their words in a child text element.
    private static func childText(_ el: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 3 else { return nil }
        for child in children(el).prefix(6) {
            if let t = (value(child, kAXValueAttribute) as? String) ?? string(child, kAXTitleAttribute) ?? string(child, kAXDescriptionAttribute),
               !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let t = childText(child, depth: depth + 1) { return t }
        }
        return nil
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
