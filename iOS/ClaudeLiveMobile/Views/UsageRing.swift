import SwiftUI
import ClaudeLiveKit

/// One limit, as a ring.
///
/// Rings on the Home tab and bars in the Usage tab, which is not indecision:
/// a ring answers "how full" in one look and nothing else, while a bar has a
/// length to compare and room for a date underneath. Home asks the first
/// question, the Usage tab the second.
struct UsageRing: View {
    let title: String
    let window: UsageWindow
    var diameter: CGFloat = 84
    var warn: Double = 0.75
    var danger: Double = 0.90

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: 8)

                Circle()
                    .trim(from: 0, to: window.utilization.clamped(to: 0...1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    // Starts at the top, like a clock, rather than at three
                    // o'clock where trimming naturally begins.
                    .rotationEffect(.degrees(-90))

                Text(Format.percent(window.utilization))
                    .font(.system(size: diameter * 0.26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .frame(width: diameter, height: diameter)

            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private var tint: Color {
        if window.status == "rejected" { return GlowRGB.failed.color }
        switch UsageLevel.level(for: window.utilization, warn: warn, danger: danger) {
        case .danger: return GlowRGB.failed.color
        case .warning: return GlowRGB.waiting.color
        case .normal: return GlowRGB.done.color
        }
    }
}

#Preview("Anelli") {
    ZStack {
        ThemedBackground()
        HStack(spacing: 28) {
            UsageRing(title: "5 ore", window: UsageWindow(utilization: 0.78, resetAt: nil, status: nil))
            UsageRing(title: "7 giorni", window: UsageWindow(utilization: 0.41, resetAt: nil, status: nil))
        }
    }
}
