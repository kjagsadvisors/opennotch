import AppKit
import SwiftUI

// Shared building blocks for onboarding. Everything uses system fonts, SF Symbols, semantic
// colors and Liquid Glass, so light/dark mode and accessibility settings just work.

extension View {
    /// The one prominent button on each screen.
    func primaryAction() -> some View {
        buttonStyle(PrimaryGlassButtonStyle())
    }
}

/// Accent-tinted Liquid Glass capsule with a white label. Unlike the system prominent style it
/// looks the same whether or not the window is focused, so the call to action never fades out.
struct PrimaryGlassButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 14 : 22)
            .padding(.vertical, compact ? 7 : 11)
            .background(Capsule().fill(Color.accentColor.gradient))
            .glassEffect(.clear.interactive(), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct StepTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 30, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
    }
}

struct StepBody: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct Wordmark: View {
    var size: CGFloat = 72
    var body: some View {
        HStack(spacing: size * 0.18) {
            Image(systemName: "waveform")
                .font(.system(size: size * 0.8, weight: .bold))
            Text(Brand.name)
                .font(.system(size: size, weight: .bold))
                .tracking(-size * 0.02)
        }
    }
}

struct ProgressTrack: View {
    let progress: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.35)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(10, g.size.width * progress))
            }
        }
        .frame(height: 6)
        .animation(.smooth(duration: 0.6), value: progress)
    }
}

struct SpeakerToggle: View {
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            Image(systemName: on ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(on ? "Turn narration off" : "Turn narration on")
    }
}

extension TriggerKey {
    var nsFlag: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        }
    }

    var symbol: String {
        switch self {
        case .fn: return "globe"
        case .rightOption: return "option"
        case .rightCommand: return "command"
        case .rightControl: return "control"
        }
    }

    var capLabel: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "option"
        case .rightCommand: return "command"
        case .rightControl: return "control"
        }
    }

    static func current(_ mode: Mode) -> TriggerKey {
        let raw = Pref.string(mode == .dictation ? Pref.dictationKey : Pref.commandKey)
        return TriggerKey(rawValue: raw) ?? (mode == .dictation ? .fn : .rightOption)
    }
}

/// A Mac keyboard key, drawn the way the physical key is labeled.
struct Keycap: View {
    let symbol: String?
    let label: String
    var side: String?
    var lit = false
    var scale: CGFloat = 1

    init(_ key: TriggerKey, lit: Bool = false, scale: CGFloat = 1) {
        symbol = key.symbol
        label = key.capLabel
        side = key == .fn ? nil : "right"
        self.lit = lit
        self.scale = scale
    }

    init(label: String, symbol: String? = nil, scale: CGFloat = 1) {
        self.label = label
        self.symbol = symbol
        self.scale = scale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                if let symbol { Image(systemName: symbol).font(.system(size: 13 * scale, weight: .medium)) }
            }
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline, spacing: 3 * scale) {
                Text(label).font(.system(size: 11 * scale, weight: .medium))
                if let side { Text(side).font(.system(size: 8 * scale)).opacity(0.6) }
                Spacer(minLength: 0)
            }
        }
        .padding(8 * scale)
        .frame(width: (label.count > 3 ? 86 : 60) * scale, height: 56 * scale)
        .foregroundStyle(lit ? Color.white : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .fill(lit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
                .shadow(color: lit ? Color.accentColor.opacity(0.55) : .black.opacity(0.12), radius: lit ? 14 * scale : 1.5, y: lit ? 0 : 1.5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous).strokeBorder(.quaternary, lineWidth: lit ? 0 : 1)
        }
        .scaleEffect(lit ? 0.96 : 1)
        .animation(.snappy(duration: 0.18), value: lit)
    }
}

/// Expandable card for one permission, with its state and the button that grants it.
struct PermissionCard: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let expanded: Bool
    var busy = false
    let actionTitle: String?
    let action: () -> Void
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: granted ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(granted ? Color.green : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 24)
                Text(title).font(.headline)
                Spacer()
                if granted { Text("Done").font(.subheadline).foregroundStyle(.secondary) }
            }
            if expanded && !granted {
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 36)
                if busy {
                    ProgressView().controlSize(.small).padding(.leading, 36)
                } else if let actionTitle {
                    Button(actionTitle, action: action)
                        .buttonStyle(PrimaryGlassButtonStyle(compact: true))
                        .padding(.leading, 36)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(expanded && !granted ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .animation(.smooth(duration: 0.3), value: expanded)
        .animation(.smooth(duration: 0.3), value: granted)
    }
}

struct StatCard: View {
    let title: String
    let value: Int
    let unit: String
    var highlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(value)").font(.system(size: 52, weight: .semibold)).contentTransition(.numericText(value: Double(value)))
                Text(unit).font(.headline).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(width: 260, alignment: .leading)
        .glassEffect(highlight ? .regular.tint(.accentColor.opacity(0.18)) : .regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Floating hint shown next to System Settings while the user grants Accessibility.
struct AccessibilityGuide: View {
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 44, height: 44)
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                .help("Drag into the Accessibility list if \(Brand.name) isn't there")
            VStack(alignment: .leading, spacing: 3) {
                Text("Turn on \(Brand.name) in the list").font(.headline)
                Text("Not listed? Drag this icon into it.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        }
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(4)
    }
}
