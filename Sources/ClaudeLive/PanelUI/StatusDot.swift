import SwiftUI

/// The per-project Claude Code status indicator.
///
/// - working: green, with a pulsing halo
/// - waiting for input: orange, blinking (the one state that should catch the eye)
/// - error: red, steady
/// - idle: grey, steady
/// - unknown / no session: hollow grey outline
struct StatusDot: View {
    let status: ClaudeProjectStatus?

    private let size: CGFloat = 6.5

    @State private var pulsing = false

    private var activity: ClaudeActivity? { status?.state }

    private var color: Color {
        switch activity {
        case .working: return PanelTheme.color(for: .normal)
        case .waitingInput: return PanelTheme.color(for: .warning)
        case .error: return PanelTheme.color(for: .danger)
        case .idle: return Color.secondary.opacity(0.55)
        case .unknown, .none: return Color.secondary.opacity(0.35)
        }
    }

    var body: some View {
        ZStack {
            // Expanding halo while Claude is working.
            if activity == .working {
                Circle()
                    .fill(color.opacity(0.30))
                    .frame(width: size, height: size)
                    .scaleEffect(pulsing ? 2.3 : 1.0)
                    .opacity(pulsing ? 0 : 0.9)
            }

            if activity == .unknown || activity == nil {
                Circle()
                    .strokeBorder(color, lineWidth: 1.2)
                    .frame(width: size, height: size)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .opacity(activity == .waitingInput && pulsing ? 0.2 : 1)
            }
        }
        // Reserve the halo's full extent so the row doesn't reflow when the
        // animation starts.
        .frame(width: size * 2.4, height: size * 2.4)
        .onAppear { restartAnimation() }
        .onChange(of: activity) { _, _ in restartAnimation() }
    }

    private func restartAnimation() {
        pulsing = false
        switch activity {
        case .working:
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        case .waitingInput:
            withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        default:
            break
        }
    }
}
