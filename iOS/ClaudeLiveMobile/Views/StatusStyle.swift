import SwiftUI
import ClaudeLiveKit

/// How a state looks, in one place.
///
/// The colours are the notch's own — `GlowRGB.waiting`, `.done`, `.failed` — so
/// a project that is amber on the Mac is the same amber here. Two devices
/// reporting one event have to agree on its colour, or they read as two
/// unrelated things happening at once.
extension ClaudeActivity {
    var tint: Color {
        switch self {
        case .waitingInput: return GlowRGB.waiting.color
        case .working: return .accentColor
        case .error: return GlowRGB.failed.color
        case .idle: return .secondary
        case .unknown: return .secondary
        }
    }

    /// SF Symbol for the state, for the places a dot is not enough.
    var symbol: String {
        switch self {
        case .waitingInput: return "bell.badge.fill"
        case .working: return "gearshape.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

/// The dot that carries a project's state in a list.
struct StatusDot: View {
    let state: ClaudeActivity
    var isStale: Bool = false
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: size, height: size)
            // A stale record is drawn faded rather than hidden or recoloured:
            // "I am not sure any more" is different from both "fine" and "wrong".
            .opacity(isStale ? 0.4 : 1)
            .overlay {
                if state == .working {
                    Circle()
                        .stroke(state.tint.opacity(0.35), lineWidth: 4)
                        .scaleEffect(1.9)
                }
            }
    }
}

#Preview("Pallini") {
    HStack(spacing: 24) {
        ForEach([ClaudeActivity.waitingInput, .working, .error, .idle, .unknown], id: \.self) { state in
            VStack(spacing: 10) {
                StatusDot(state: state, size: 14)
                Text(state.label).font(.caption2)
            }
        }
    }
    .padding(40)
}
