import SwiftUI

/// Full-screen welcome: the desktop dims, the wordmark glows, and we ask the user's name.
struct IntroView: View {
    @ObservedObject var model: Onboarding
    @FocusState private var nameFocused: Bool
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
            RadialGradient(colors: [Color.accentColor.opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: 700)

            Group {
                switch model.introPhase {
                case .splash: splash
                case .name: nameEntry
                case .greeting: greeting
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))

            VStack {
                Spacer()
                HStack {
                    SpeakerToggle(on: $model.narrationOn)
                    Spacer()
                    Button("Skip intro") { model.finishIntro() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(32)
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.5), value: model.introPhase)
        .onAppear { withAnimation(.smooth(duration: 1.1).delay(0.2)) { appeared = true } }
    }

    private var splash: some View {
        VStack(spacing: 44) {
            Wordmark(size: 96)
                .shadow(color: .white.opacity(0.55), radius: 28)
                .shadow(color: .accentColor.opacity(0.6), radius: 60)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.92)
                .blur(radius: appeared ? 0 : 12)
            Button { model.beginNameEntry() } label: {
                Text("Get Started").font(.title3.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 6)
            }
            .buttonStyle(.glass)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .opacity(appeared ? 1 : 0)
        }
    }

    private var nameEntry: some View {
        VStack(spacing: 34) {
            VStack(spacing: 8) {
                Text("Welcome to \(Brand.name). I'm your voice for this Mac.")
                Text("What should I call you?")
            }
            .font(.system(size: 34, weight: .semibold))
            .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                TextField("First name", text: $model.name)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($nameFocused)
                    .onSubmit { model.submitName() }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .frame(width: 340)
                    .glassEffect(.regular.interactive(), in: Capsule())
                Button { model.submitName() } label: {
                    Image(systemName: "arrow.up").font(.title3.weight(.bold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(model.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { nameFocused = true } }
    }

    private var greeting: some View {
        Text("Hi \(model.displayName), it's great to meet you.")
            .font(.system(size: 40, weight: .semibold))
            .shadow(color: .white.opacity(0.35), radius: 20)
    }
}
