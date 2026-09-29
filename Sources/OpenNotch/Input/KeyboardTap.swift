import AppKit
import CoreGraphics

enum Mode: String {
    case dictation, command
}

enum TriggerKey: String, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightControl

    var id: String { rawValue }

    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        }
    }

    var label: String {
        switch self {
        case .fn: return "Fn / Globe"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        }
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

    private func trigger(for mode: Mode) -> TriggerKey {
        let key = mode == .dictation ? Pref.dictationKey : Pref.commandKey
        return TriggerKey(rawValue: Pref.string(key)) ?? (mode == .dictation ? .fn : .rightOption)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            for mode in [Mode.dictation, .command] {
                let key = trigger(for: mode)
                guard code == key.keyCode else { continue }
                let down = event.flags.contains(key.flag)
                if down, held == nil {
                    held = mode
                    onPress?(mode)
                } else if !down, held == mode {
                    held = nil
                    onRelease?(mode)
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
