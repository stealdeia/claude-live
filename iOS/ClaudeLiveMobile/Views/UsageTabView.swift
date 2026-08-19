import SwiftUI
import ClaudeLiveKit

/// The limits in full: every window, with its number and when it resets.
struct UsageTabView: View {
    let snapshot: RemoteSnapshot?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let usage = snapshot?.usage {
                    if let five = usage.fiveHour { card("5 ore", five, isRepresentative: usage.representativeClaim == "five_hour") }
                    if let seven = usage.sevenDay { card("7 giorni", seven, isRepresentative: usage.representativeClaim == "seven_day") }
                    if let opus = usage.opusSevenDay { card("Opus, 7 giorni", opus, isRepresentative: false) }

                    account(usage)
                } else {
                    GlassCard {
                        Text("Nessun dato di utilizzo dal Mac.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func card(_ title: String, _ window: UsageWindow, isRepresentative: Bool) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if isRepresentative {
                        // Which window the API itself considers the limiting one.
                        Text("la più stretta")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    Text(Format.percent(window.utilization))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(tint(window))
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule()
                            .fill(tint(window))
                            // Clamped: utilisation legitimately passes 1 when the
                            // request that crosses the limit lands.
                            .frame(width: geometry.size.width * window.utilization.clamped(to: 0...1))
                    }
                }
                .frame(height: 8)

                if let resetAt = window.resetAt {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("si azzera in \(Format.countdown(to: resetAt))")
                        Text("·")
                        Text(Format.clock.string(from: resetAt))
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                }

                if window.status == "rejected" {
                    Label("le richieste vengono rifiutate", systemImage: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(GlowRGB.failed.color)
                }
            }
        }
    }

    private func account(_ usage: UsageSnapshot) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                if let plan = usage.subscriptionType {
                    LabeledContent("Piano", value: plan.capitalized)
                }
                LabeledContent("Letto", value: Format.age(since: usage.fetchedAt))
                if usage.wasRateLimited {
                    // A 429 is a perfectly valid reading here, not a failure —
                    // the Mac reads the limits from the headers of a refusal.
                    Label("dato letto da una risposta 429", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.75))
        }
    }

    private func tint(_ window: UsageWindow) -> Color {
        if window.status == "rejected" { return GlowRGB.failed.color }
        switch UsageLevel.level(for: window.utilization, warn: 0.75, danger: 0.90) {
        case .danger: return GlowRGB.failed.color
        case .warning: return GlowRGB.waiting.color
        case .normal: return GlowRGB.done.color
        }
    }
}

#Preview("Utilizzo") {
    ZStack {
        ThemedBackground()
        UsageTabView(snapshot: RemoteSnapshot.sample(now: Date()))
    }
    .preferredColorScheme(.dark)
}
