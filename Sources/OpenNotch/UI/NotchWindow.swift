import AppKit
import SwiftUI

/// What the notch is showing.
final class NotchState: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening
        case working
        case message
        case confirm
    }

    @Published var phase: Phase = .hidden
    @Published var mode: Mode = .dictation
    @Published var transcript = ""
    @Published var level: Float = 0
    @Published var title = ""
    @Published var detail: String?
    @Published var icon = "waveform"
    @Published var isError = false

    /// Notch geometry for the screen the panel is on.
    @Published var notchSize = CGSize(width: 190, height: 32)

    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Set on messages that do something when clicked (e.g. the Pro nudge).
    var onTap: (() -> Void)?
}

/// Borderless, non-activating panel pinned over the notch. It never takes focus from the
/// user's app, so keystrokes and AX actions still land where the user was working.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class NotchWindowController {
    static let panelSize = CGSize(width: 640, height: 320)

    let state: NotchState
    private let panel: NotchPanel

    init(state: NotchState) {
        self.state = state
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: NotchView(state: state))
        reposition()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reposition()
        }
    }

    /// The built-in display if it has a notch, otherwise the main screen.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    func reposition() {
        guard let screen else { return }
        let f = screen.frame
        panel.setFrameOrigin(NSPoint(x: f.midX - Self.panelSize.width / 2, y: f.maxY - Self.panelSize.height))

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.notchSize = CGSize(width: f.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            // No notch: hang a pill from the menu bar instead.
            state.notchSize = CGSize(width: 180, height: max(24, f.maxY - screen.visibleFrame.maxY))
        }
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
    }

    /// Only interactive while a card with buttons is up, so the menu bar stays clickable.
    func setInteractive(_ on: Bool) {
        panel.ignoresMouseEvents = !on
    }
}
