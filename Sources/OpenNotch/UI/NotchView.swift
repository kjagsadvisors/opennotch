import SwiftUI

struct NotchView: View {
    @ObservedObject var state: NotchState

    private let ear: CGFloat = 8
    private let side: CGFloat = 52

    var body: some View {
        island
            .frame(width: NotchWindowController.panelSize.width, height: NotchWindowController.panelSize.height, alignment: .top)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.phase)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.transcript.isEmpty)
    }

    private var accent: Color {
        if state.isError { return .red }
        return state.mode == .dictation ? Color(red: 0.45, green: 0.95, blue: 0.75) : Color(red: 0.62, green: 0.55, blue: 1.0)
    }

    private var expanded: Bool {
        switch state.phase {
        case .message, .confirm: return true
        case .listening: return !state.transcript.isEmpty
        default: return false
        }
    }

    private var contentWidth: CGFloat {
        let compact = state.notchSize.width + side * 2
        switch state.phase {
        case .hidden: return state.notchSize.width
        case .listening: return state.transcript.isEmpty ? compact : max(compact, 420)
        case .working: return compact
        case .message, .confirm: return max(compact, 460)
        }
    }

    private var island: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading.frame(width: side)
                Spacer(minLength: state.notchSize.width)
                trailing.frame(width: side)
            }
            .frame(height: state.notchSize.height)

            if expanded {
                content
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: contentWidth)
        .padding(.horizontal, ear)
        .background(NotchShape(ear: ear, bottomRadius: expanded ? 22 : 12).fill(.black))
        .opacity(state.phase == .hidden ? 0 : 1)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var leading: some View {
        switch state.phase {
        case .listening:
            Image(systemName: state.mode == .dictation ? "mic.fill" : "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
        case .working:
            ProgressView().controlSize(.small).tint(accent)
        case .message, .confirm:
            Image(systemName: state.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch state.phase {
        case .listening: Waveform(level: state.level, color: accent)
        case .working:
            Text(state.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
        default: EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .listening:
            Text(state.transcript)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .message:
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title).font(.system(size: 13, weight: .semibold))
                if let d = state.detail {
                    Text(d).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.8)).lineLimit(10).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { state.onTap?() }

        case .confirm:
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
                    if let d = state.detail {
                        Text(d).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(9)
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    NotchButton(title: "Cancel", hint: "esc", prominent: false, accent: accent) { state.onCancel?() }
                    NotchButton(title: "Run", hint: "⏎", prominent: true, accent: accent) { state.onConfirm?() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        default:
            EmptyView()
        }
    }
}

private struct NotchButton: View {
    let title: String
    let hint: String
    let prominent: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(hint).font(.system(size: 10, weight: .medium)).opacity(0.6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(prominent ? accent : Color.white.opacity(0.12)))
            .foregroundStyle(prominent ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

private struct Waveform: View {
    let level: Float
    let color: Color
    private let weights: [CGFloat] = [0.5, 0.85, 1.0, 0.7, 0.45]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 3 + CGFloat(level) * 14 * weights[i])
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

/// Flat top with small concave "ears" so it melts into the menu bar, rounded bottom.
struct NotchShape: Shape {
    var ear: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let t = ear
        let b = min(bottomRadius, (r.height - t) / 2, (r.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}
