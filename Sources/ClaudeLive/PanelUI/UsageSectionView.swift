import SwiftUI

/// One labelled progress bar: name, percentage, coloured fill, reset countdown.
struct UsageBarView: View {
    let title: String
    let window: UsageWindow?
    let warn: Double
    let danger: Double
    /// Dim everything when the reading is known to be out of date.
    let isStale: Bool

    private var level: UsageLevel {
        UsageLevel.level(for: window?.utilization ?? 0, warn: warn, danger: danger)
    }

    private var fillColor: Color {
        PanelTheme.color(for: level).opacity(isStale ? 0.45 : 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(PanelTheme.labelFont)
                    .foregroundStyle(PanelTheme.secondaryText)

                Spacer(minLength: 4)

                if let window {
                    Text(Format.percent(window.utilization))
                        .font(PanelTheme.valueFont)
                        .foregroundStyle(fillColor)
                } else {
                    Text("—")
                        .font(PanelTheme.valueFont)
                        .foregroundStyle(PanelTheme.secondaryText)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PanelTheme.barTrack)

                    Capsule()
                        .fill(fillColor)
                        .frame(
                            width: max(
                                window.map { CGFloat($0.utilization) } ?? 0,
                                // A hairline sliver reads better than nothing at 0%.
                                (window?.utilization ?? 0) > 0 ? 0.02 : 0
                            ) * geometry.size.width
                        )
                        .animation(.easeOut(duration: 0.35), value: window?.utilization ?? 0)
                }
            }
            .frame(height: PanelTheme.barHeight)

            // Live countdown to the window reset.
            if let resetAt = window?.resetAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 8, weight: .semibold))
                        Text("reset in \(Format.countdown(to: resetAt, now: context.date))")
                    }
                    .font(PanelTheme.captionFont)
                    .foregroundStyle(PanelTheme.secondaryText)
                }
            }
        }
    }
}

/// The two account-limit bars, plus the Opus bar when the plan reports one.
struct UsageSectionView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var settings: Settings

    private var isStale: Bool {
        switch monitor.state {
        case .stale, .unavailable: return true
        case .idle, .refreshing, .live: return false
        }
    }

    /// Why the numbers are dimmed, when they are.
    ///
    /// Dimming on its own is what made a user ask why the app looked "switched
    /// off": it signals *that* something is wrong and nothing about *what*. The
    /// reason was already available — it just was not on screen.
    private var staleMessage: String? {
        switch monitor.state {
        case .stale(let reason): return reason.message
        case .unavailable(let message): return message
        case .idle, .refreshing, .live: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let staleMessage {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(staleMessage)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(PanelTheme.captionFont)
                .foregroundStyle(PanelTheme.color(for: .warning))
            }

            UsageBarView(
                title: "Sessione 5h",
                window: monitor.snapshot?.fiveHour,
                warn: settings.warnThreshold,
                danger: settings.dangerThreshold,
                isStale: isStale
            )

            UsageBarView(
                title: "Settimana 7g",
                window: monitor.snapshot?.sevenDay,
                warn: settings.warnThreshold,
                danger: settings.dangerThreshold,
                isStale: isStale
            )

            if let opus = monitor.snapshot?.opusSevenDay {
                UsageBarView(
                    title: "Opus 7g",
                    window: opus,
                    warn: settings.warnThreshold,
                    danger: settings.dangerThreshold,
                    isStale: isStale
                )
            }
        }
    }
}
