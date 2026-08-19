import SwiftUI
import ClaudeLiveKit

/// The limits, as three bars.
///
/// Bars rather than the notch's rings: rings work at a glance on a strip a few
/// pixels tall, but on a full screen there is room to also say *when it resets*,
/// and that number is the one that changes what you do next.
struct UsageBarsView: View {
    let usage: UsageSnapshot
    /// Thresholds mirror the Mac's `warnThreshold` / `dangerThreshold`.
    var warn: Double = 0.75
    var danger: Double = 0.90

    var body: some View {
        SectionCard(title: "Utilizzo", subtitle: freshness) {
            VStack(spacing: 12) {
                if let five = usage.fiveHour {
                    bar("5 ore", five)
                }
                if let seven = usage.sevenDay {
                    bar("7 giorni", seven)
                }
                if let opus = usage.opusSevenDay {
                    bar("Opus, 7 giorni", opus)
                }
            }
        }
    }

    private var freshness: String {
        let age = Format.age(since: usage.fetchedAt)
        return usage.wasRateLimited ? "limite raggiunto · \(age)" : age
    }

    private func bar(_ title: String, _ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.footnote)
                Spacer()
                Text(Format.percent(window.utilization))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(colour(for: window))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(colour(for: window))
                        // Clamped, because utilisation legitimately exceeds 1:
                        // the request that crosses the limit pushes it past 100%,
                        // and a bar wider than its track would spill out.
                        .frame(width: geometry.size.width * window.utilization.clamped(to: 0...1))
                }
            }
            .frame(height: 7)

            if let resetAt = window.resetAt {
                Text("si azzera in \(Format.countdown(to: resetAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func colour(for window: UsageWindow) -> Color {
        // A window whose requests are being refused is full whatever the number
        // says — the Mac makes the same call in UsageAPIClient.
        if window.status == "rejected" { return GlowRGB.failed.color }
        switch UsageLevel.level(for: window.utilization, warn: warn, danger: danger) {
        case .danger: return GlowRGB.failed.color
        case .warning: return GlowRGB.waiting.color
        case .normal: return GlowRGB.done.color
        }
    }
}

#Preview("Utilizzo") {
    ScrollView {
        VStack(spacing: 14) {
            UsageBarsView(usage: RemoteSnapshot.sample().usage!)
            UsageBarsView(usage: RemoteSnapshot.sampleQuiet().usage!)
        }
        .padding()
    }
    .background(.background.tertiary)
}
