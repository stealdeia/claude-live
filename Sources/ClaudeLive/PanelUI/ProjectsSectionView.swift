import SwiftUI
import ClaudeLiveKit

/// The project list: one compact row per open VS Code project, each carrying the
/// live Claude Code status from the hooks, the number of editor windows it is
/// open in, and the number of Claude Code sessions ("chats") running in it.
///
/// A project with more than one chat lists them underneath, one row each, because
/// the project row can only show the most urgent of them — which is the right
/// summary and the wrong answer to "what is each of them doing".
struct ProjectsSectionView: View {
    @ObservedObject var projects: ProjectsMonitor
    @ObservedObject var status: ClaudeStatusStore
    /// Read for the glow palettes: a row lights in the same colour as the strip
    /// around the notch, because it is reporting the same event.
    @ObservedObject var settings: Settings
    let onInstallHooks: () -> Void

    private let rowHeight: CGFloat = 24
    private let chatRowHeight: CGFloat = 17
    /// Beyond this the list scrolls instead of growing the panel indefinitely.
    private let maxListHeight: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if !projects.isEditorRunning {
                emptyState("Visual Studio Code non è in esecuzione")
            } else if projects.projects.isEmpty {
                emptyState(projects.isRefreshing ? "Lettura progetti…" : "Nessun progetto aperto")
            } else {
                list
                if !status.hooksInstalled {
                    hooksPrompt
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Progetti")
                .font(PanelTheme.labelFont)
                .foregroundStyle(PanelTheme.secondaryText)

            Spacer(minLength: 4)

            // A count, not a bell: the signal is the strip around the notch now.
            if status.waitingCount > 0 {
                Text("\(status.waitingCount) in attesa")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PanelTheme.color(for: .warning))
            } else if !projects.projects.isEmpty {
                Text("\(projects.projects.count)")
                    .font(PanelTheme.captionFont)
                    .foregroundStyle(PanelTheme.secondaryText)
            }
        }
    }

    private var list: some View {
        let rows = VStack(spacing: 1) {
            ForEach(projects.projects) { project in
                ProjectRowView(
                    project: project,
                    status: status.status(for: project),
                    sessions: status.sessions(for: project),
                    alert: status.alert(for: project),
                    palette: palette(for: status.alert(for: project))
                ) {
                    projects.focus(project)
                    // Clicking the project is the gesture that acknowledges its
                    // alert, and so turns the strip off.
                    status.clearAlert(for: project)
                }
            }
        }

        // Estimated, not measured: a scroll view has to be given a height, and
        // measuring the content to decide whether to put it in a scroll view is
        // circular. Rows have a known height, so the estimate is exact enough.
        return Group {
            if estimatedListHeight > maxListHeight {
                ScrollView(.vertical, showsIndicators: false) {
                    rows
                }
                .frame(height: maxListHeight)
            } else {
                rows
            }
        }
    }

    /// Nil when there is nothing to light, which is also what stops the rows from
    /// animating when nothing is pending.
    private func palette(for alert: ClaudeAlert?) -> NotchGlowPalette? {
        guard settings.glowEnabled, let alert else { return nil }
        return settings.glowStyle(for: alert.kind).palette
    }

    private var estimatedListHeight: CGFloat {
        projects.projects.reduce(0) { total, project in
            let chats = status.sessions(for: project).count
            // Chats are only listed when there is more than one — see ProjectRowView.
            return total + rowHeight + (chats > 1 ? CGFloat(chats) * chatRowHeight : 0)
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(PanelTheme.captionFont)
            .foregroundStyle(PanelTheme.secondaryText)
            .padding(.vertical, 2)
    }

    private var hooksPrompt: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(PanelTheme.separator)
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 9, weight: .semibold))
                Text("Hook di Claude Code non installati: lo stato per progetto non è disponibile.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(PanelTheme.captionFont)
            .foregroundStyle(PanelTheme.secondaryText)

            Button("Installa hook…", action: onInstallHooks)
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
        }
    }
}

/// A single project: status dot, name, badge, counters, click to focus — plus one
/// row per chat when there is more than one.
struct ProjectRowView: View {
    let project: VSCodeProject
    let status: ClaudeProjectStatus?
    /// Every Claude Code session in this project, most urgent first.
    let sessions: [ClaudeSessionStatus]
    /// The unacknowledged event, if any. Nil means an ordinary row.
    let alert: ClaudeAlert?
    /// How to light it. Nil when the strip is off or there is no alert.
    let palette: NotchGlowPalette?
    let onSelect: () -> Void

    @State private var isHovering = false

    private var isWaiting: Bool { status?.state == .waitingInput }

    /// One chat adds nothing the project row doesn't already say: its state *is*
    /// the project's state. Two or more do, so those are listed.
    private var showsChats: Bool { sessions.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSelect) {
                summary
            }
            .buttonStyle(.plain)
            .disabled(project.path == nil)
            .onHover { isHovering = $0 }
            .help(tooltip)

            if showsChats {
                VStack(spacing: 0) {
                    ForEach(sessions) { session in
                        ChatRowView(
                            session: session,
                            // Only the chat that raised it: with several running, "one
                            // of them needs you" is the half of the message that was
                            // missing.
                            palette: session.sessionID == alert?.sessionID ? palette : nil
                        )
                    }
                }
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 4) {
            StatusDot(status: status)

            Text(project.name)
                .font(.system(size: 11, weight: isWaiting ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)

            if let badge = status?.badge {
                Text(badge)
                    .font(.system(size: 8.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(badgeBackground, in: Capsule())
                    .foregroundStyle(badgeForeground)
                    .layoutPriority(-1)
            }

            Spacer(minLength: 2)

            // How many editor windows have it open. Only when it is more than
            // one: "1" on every row is noise.
            if project.windowCount > 1 {
                counter(symbol: "macwindow", value: project.windowCount)
            }

            // How many Claude Code conversations are running in it.
            if !sessions.isEmpty {
                counter(
                    symbol: "text.bubble",
                    value: sessions.count,
                    tint: isWaiting ? PanelTheme.color(for: .warning) : nil
                )
            }

            // No resolved path means we can't ask VS Code to focus it.
            if project.path == nil {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 8))
                    .foregroundStyle(PanelTheme.secondaryText)
            } else {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(PanelTheme.secondaryText)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.trailing, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(rowBackground)
        )
        .background(GlowRowBackground(palette: palette, cornerRadius: 5))
        .contentShape(Rectangle())
    }

    private func counter(symbol: String, value: Int, tint: Color? = nil) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 7.5, weight: .semibold))
            Text("\(value)")
                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 3.5)
        .padding(.vertical, 1)
        .background((tint ?? Color.primary).opacity(tint == nil ? 0.09 : 0.18), in: Capsule())
        .foregroundStyle(tint ?? PanelTheme.secondaryText)
    }

    private var rowBackground: Color {
        if isHovering && project.path != nil { return Color.primary.opacity(0.08) }
        // The pulsing background covers the "needs you" case now; this stays for a
        // pending request the user has already acknowledged.
        if isWaiting && palette == nil { return PanelTheme.color(for: .warning).opacity(0.12) }
        return .clear
    }

    private var badgeBackground: Color {
        switch status?.state {
        case .waitingInput: return PanelTheme.color(for: .warning).opacity(0.22)
        case .error: return PanelTheme.color(for: .danger).opacity(0.18)
        default: return Color.primary.opacity(0.08)
        }
    }

    private var badgeForeground: Color {
        switch status?.state {
        case .waitingInput: return PanelTheme.color(for: .warning)
        case .error: return PanelTheme.color(for: .danger)
        default: return PanelTheme.secondaryText
        }
    }

    private var tooltip: String {
        var lines = [project.displayPath ?? "\(project.name) — percorso non trovato in workspaceStorage"]
        if let alert { lines.append("\(alert.kind.label) — clicca per spegnere il segnale") }
        if project.windowCount > 1 { lines.append("\(project.windowCount) finestre di VS Code") }
        if let status { lines.append(status.tooltip) }
        return lines.joined(separator: "\n\n")
    }
}

/// One Claude Code session inside a project: what that single chat is doing.
private struct ChatRowView: View {
    let session: ClaudeSessionStatus
    let palette: NotchGlowPalette?

    var body: some View {
        HStack(spacing: 3) {
            // Indent under the project's status dot, so the rows read as its
            // children without drawing a tree.
            Spacer().frame(width: 9)

            StatusDot(activity: session.state, size: 5)

            Text(session.chatLabel)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(PanelTheme.secondaryText)

            Text(session.activityLabel)
                .font(.system(size: 9.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(color)
                .layoutPriority(-1)

            Spacer(minLength: 2)

            Text(Format.age(since: session.updatedAt))
                .font(PanelTheme.captionFont)
                .foregroundStyle(PanelTheme.secondaryText.opacity(0.7))
        }
        .padding(.trailing, 5)
        .padding(.vertical, 0.5)
        .background(GlowRowBackground(palette: palette, cornerRadius: 4))
        .help(session.tooltip)
    }

    /// Only the states that mean something is happening are coloured; the rest
    /// stay secondary, so a busy list still reads at a glance.
    private var color: Color {
        switch session.state {
        case .working: return PanelTheme.color(for: .normal)
        case .waitingInput: return PanelTheme.color(for: .warning)
        case .error: return PanelTheme.color(for: .danger)
        case .idle, .unknown: return PanelTheme.secondaryText
        }
    }
}


/// The row's share of the notification signal: the same travelling light as the
/// strip around the notch, in the same colour and the same rhythm, laid flat.
///
/// Both read from `GlowBand`, so they cannot drift apart — the point is that the
/// notch says "something happened" and the row says "here". Kept faint: the row has
/// text on it, and the aim is to draw the eye, not to become the content.
private struct GlowRowBackground: View {
    let palette: NotchGlowPalette?
    let cornerRadius: CGFloat

    /// Ceiling on the brightness. Anything stronger and the project's name stops
    /// being readable at the moment the band passes under it.
    private let maxOpacity: Double = 0.34

    var body: some View {
        if let palette {
            // Nothing animates unless something is pending: with no alert this view
            // is an `EmptyView` and no clock runs.
            TimelineView(.animation) { context in
                let stops = GlowBand.stops(
                    phase: GlowBand.phase(at: context.date),
                    palette: palette,
                    maxOpacity: maxOpacity
                )
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
            }
        }
    }
}
