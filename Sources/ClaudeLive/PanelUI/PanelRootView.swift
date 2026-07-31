import SwiftUI

/// Actions the panel needs from its host. Keeping them in a struct (rather than
/// reaching for AppKit) is what lets the same view tree be hosted elsewhere —
/// e.g. the planned notch surface.
struct PanelActions {
    var refreshNow: () -> Void = {}
    var toggleCollapsed: () -> Void = {}
    var openSettings: () -> Void = {}
    var installHooks: () -> Void = {}
    var quit: () -> Void = {}
}

/// The panel's whole content: header, usage bars, status footer.
/// Phases 2 and 3 add their sections between the bars and the footer.
struct PanelRootView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var projects: ProjectsMonitor
    @ObservedObject var status: ClaudeStatusStore
    @ObservedObject var settings: Settings
    let actions: PanelActions

    var body: some View {
        Group {
            if settings.panelCollapsed {
                CollapsedPanelView(
                    monitor: monitor,
                    projects: projects,
                    status: status,
                    settings: settings,
                    actions: actions
                )
            } else {
                expanded
            }
        }
        .background(PanelBackground(cornerRadius: settings.panelCollapsed
                                    ? PanelTheme.collapsedCornerRadius
                                    : PanelTheme.cornerRadius))
        .opacity(settings.panelOpacity)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider().overlay(PanelTheme.separator)

            UsageSectionView(monitor: monitor, settings: settings)

            Divider().overlay(PanelTheme.separator)

            ProjectsSectionView(
                projects: projects,
                status: status,
                onInstallHooks: actions.installHooks
            )

            Divider().overlay(PanelTheme.separator)

            footer
        }
        .padding(PanelTheme.contentPadding)
        .frame(width: PanelTheme.expandedWidth, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tint)

            Text("Claude Live")
                .font(PanelTheme.titleFont)

            if let plan = monitor.snapshot?.subscriptionType {
                Text(plan.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .foregroundStyle(PanelTheme.secondaryText)
            }

            Spacer(minLength: 4)

            PanelIconButton(symbol: "arrow.clockwise", help: "Aggiorna ora", action: actions.refreshNow)
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(
                    isRefreshing
                        ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                        : .default,
                    value: isRefreshing
                )

            PanelIconButton(symbol: "gearshape", help: "Impostazioni", action: actions.openSettings)
            PanelIconButton(symbol: "chevron.up", help: "Comprimi", action: actions.toggleCollapsed)
        }
    }

    private var isRefreshing: Bool {
        monitor.state == .refreshing
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch monitor.state {
            case .unavailable(let message):
                statusRow(symbol: "key.slash", color: .orange, text: message, multiline: true)

            case .stale(let reason):
                statusRow(symbol: "exclamationmark.triangle", color: .orange, text: reason.message, multiline: true)
                if let fetchedAt = monitor.snapshot?.fetchedAt {
                    lastUpdateRow(fetchedAt, prefix: "Ultimo dato")
                }

            case .idle, .refreshing:
                if let fetchedAt = monitor.snapshot?.fetchedAt {
                    lastUpdateRow(fetchedAt, prefix: "In cache")
                } else {
                    statusRow(symbol: "ellipsis", color: PanelTheme.secondaryText, text: "Lettura in corso…", multiline: false)
                }

            case .live:
                if let fetchedAt = monitor.snapshot?.fetchedAt {
                    lastUpdateRow(fetchedAt, prefix: "Aggiornato")
                }
                if monitor.snapshot?.wasRateLimited == true {
                    statusRow(symbol: "hand.raised", color: .red, text: "Limite raggiunto (HTTP 429)", multiline: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lastUpdateRow(_ date: Date, prefix: String) -> some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Text("\(prefix) \(Format.age(since: date, now: context.date))")
                .font(PanelTheme.captionFont)
                .foregroundStyle(PanelTheme.secondaryText)
        }
    }

    private func statusRow(
        symbol: String,
        color: Color,
        text: String,
        multiline: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .lineLimit(multiline ? 4 : 1)
                .fixedSize(horizontal: false, vertical: multiline)
        }
        .font(PanelTheme.captionFont)
        .foregroundStyle(color)
    }
}

/// The minimal one-line form of the panel.
struct CollapsedPanelView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var projects: ProjectsMonitor
    @ObservedObject var status: ClaudeStatusStore
    @ObservedObject var settings: Settings
    let actions: PanelActions

    private func level(_ window: UsageWindow?) -> UsageLevel {
        UsageLevel.level(
            for: window?.utilization ?? 0,
            warn: settings.warnThreshold,
            danger: settings.dangerThreshold
        )
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tint)

            miniBar(monitor.snapshot?.fiveHour, label: "5h")
            miniBar(monitor.snapshot?.sevenDay, label: "7g")

            Spacer(minLength: 2)

            if status.waitingCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 8, weight: .semibold))
                    Text("\(status.waitingCount)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                }
                .foregroundStyle(PanelTheme.color(for: .warning))
            } else if !projects.projects.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "folder")
                        .font(.system(size: 8))
                    Text("\(projects.projects.count)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(PanelTheme.secondaryText)
            }

            PanelIconButton(symbol: "chevron.down", help: "Espandi", action: actions.toggleCollapsed)
        }
        .padding(.horizontal, 8)
        .frame(width: PanelTheme.collapsedWidth, height: PanelTheme.collapsedHeight)
    }

    private func miniBar(_ window: UsageWindow?, label: String) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(PanelTheme.color(for: level(window)))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(PanelTheme.secondaryText)
            Text(window.map { Format.percent($0.utilization) } ?? "—")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
    }
}

/// Translucent material behind the panel, with a hairline border for definition.
struct PanelBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            VisualEffectBackground()
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Small square button sized for the panel's cramped header.
struct PanelIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .frame(width: 17, height: 17)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.10 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PanelTheme.secondaryText)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
