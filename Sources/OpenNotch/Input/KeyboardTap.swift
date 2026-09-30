import AppKit
import CoreGraphics

enum Mode: String {
    case dictation, command
}

/// A hold-to-talk trigger: one modifier, or two held together.
enum TriggerKey: String, CaseIterable, Identifiable {
    case fn, optionCommand, rightOption, rightCommand, rightControl

    var id: String { rawValue }

    /// Physical keys that must all be down.
    var keyCodes: Set<Int64> {
        switch self {
        case .fn: return [63]
        case .optionCommand: return [58, 55]   // left Option + left Command
        case .rightOption: return [61]
        case .rightCommand: return [54]
        case .rightControl: return [62]
        }
    }

    var label: String {
        switch self {
        case .fn: return "Fn / Globe"
        case .optionCommand: return "Left Option + Command"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        }
    }

    /// Device-dependent modifier bits, so left and right keys can be told apart.
    static let deviceBits: [Int64: UInt64] = [
        59: 0x0000_0001, 62: 0x0000_2000,   // left / right Control
        56: 0x0000_0002, 60: 0x0000_0004,   // left / right Shift
        55: 0x0000_0008, 54: 0x0000_0010,   // left / right Command
        58: 0x0000_0020, 61: 0x0000_0040,   // left / right Option
        63: CGEventFlags.maskSecondaryFn.rawValue,
    ]

    /// Which physical modifier keys are down, given a flags-changed event for one of them.
    static func update(_ down: inout Set<Int64>, keyCode: Int64, flags: UInt64) {
        guard let bit = deviceBits[keyCode] else { return }
        if flags & bit != 0 { down.insert(keyCode) } else { down.remove(keyCode) }
    }
}

/// One session-level event tap for everything keyboard: hold-to-talk triggers (never swallowed),
/// and Return/Esc while a confirmation card is up (swallowed, so they don't leak into the user's app).
final class KeyboardTap {
    var onPress: ((Mode) -> Void)?
    var onRelease: ((Mode) -> Void)?
    /// A non-trigger key went down mid-hold: the trigger was part of a shortcut, not a hold-to-talk.
    var onChord: (() -> Void)?
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?

    /// Set by the controller when Return/Esc should be captured.
    var captureConfirmKeys = false
    var captureEscape = false

    private var tap: CFMachPort?
    private var held: Mode?
    private var down: Set<Int64> = []
    /// A two-key trigger waiting a beat, so ⌥⌘ shortcuts (⌥⌘H, ⌥⌘V…) don't flash the notch.
    private var pendingChord: DispatchWorkItem?

    var isRunning: Bool { tap != nil }

    /// Needs Accessibility permission; returns false until it's granted.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let me = Unmanaged<KeyboardTap>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else { return false }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func cancelPendingChord() {
        pendingChord?.cancel()
        pendingChord = nil
    }

    private func trigger(for mode: Mode) -> TriggerKey {
        let key = mode == .dictation ? Pref.dictationKey : Pref.commandKey
        return TriggerKey(rawValue: Pref.string(key)) ?? (mode == .dictation ? .fn : .optionCommand)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            TriggerKey.update(&down, keyCode: code, flags: event.flags.rawValue)
            for mode in [Mode.dictation, .command] {
                let key = trigger(for: mode)
                let isDown = key.keyCodes.isSubset(of: down)
                if isDown, held == nil, pendingChord == nil, key.keyCodes.contains(code) {
                    if key.keyCodes.count == 1 {
                        held = mode
                        onPress?(mode)
                    } else {
                        let start = DispatchWorkItem { [weak self] in
                            guard let self, self.pendingChord != nil else { return }
                            self.pendingChord = nil
                            guard self.trigger(for: mode).keyCodes.isSubset(of: self.down), self.held == nil else { return }
                            self.held = mode
                            self.onPress?(mode)
                        }
                        pendingChord = start
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: start)
                    }
                } else if !isDown {
                    if held == mode {
                        held = nil
                        onRelease?(mode)
                    }
                    if key.keyCodes.contains(code) { cancelPendingChord() }
                }
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == 53, captureEscape || captureConfirmKeys {
                onEscape?()
                return nil
            }
            if code == 36 || code == 76, captureConfirmKeys {
                onReturn?()
                return nil
            }
            cancelPendingChord()
            if held != nil {
                held = nil
                onChord?()
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// macOS can make the 🌐 (Fn) key open emoji, switch input source or start Apple's dictation.
/// Any of those fires alongside Fn-to-talk, so onboarding asks people to set it to "Do Nothing".
enum GlobeKey {
    static var conflicts: Bool {
        guard TriggerKey.current(.dictation) == .fn || TriggerKey.current(.command) == .fn else { return false }
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        let usage = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        // Unset means the default, which opens emoji on current Macs. 0 is "Do Nothing".
        return usage != 0
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}
