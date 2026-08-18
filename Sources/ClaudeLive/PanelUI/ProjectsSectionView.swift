import SwiftUI

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

            // Draws attention only when something actually needs the user.
            if status.waitingCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 8, weight: .semibold))
                    Text("\(status.waitingCount)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                }
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
                    sessions: status.sessions(for: project)
                ) {
                    projects.focus(project)
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
                        ChatRowView(session: session)
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
        // A persistent tint so a waiting project stands out even without hover.
        if isWaiting { return PanelTheme.color(for: .warning).opacity(0.12) }
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
        if project.windowCount > 1 { lines.append("\(project.windowCount) finestre di VS Code") }
        if let status { lines.append(status.tooltip) }
        return lines.joined(separator: "\n\n")
    }
}

/// One Claude Code session inside a project: what that single chat is doing.
private struct ChatRowView: View {
    let session: ClaudeSessionStatus

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
