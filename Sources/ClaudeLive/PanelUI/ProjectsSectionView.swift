import SwiftUI

/// The project list: one compact row per open VS Code project, each carrying the
/// live Claude Code status from the hooks.
struct ProjectsSectionView: View {
    @ObservedObject var projects: ProjectsMonitor
    @ObservedObject var status: ClaudeStatusStore
    let onInstallHooks: () -> Void

    /// Beyond this the list scrolls instead of growing the panel indefinitely.
    private let maxVisibleRows = 7
    private let rowHeight: CGFloat = 24

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
                    status: status.status(for: project)
                ) {
                    projects.focus(project)
                }
            }
        }

        return Group {
            if projects.projects.count > maxVisibleRows {
                ScrollView(.vertical, showsIndicators: false) {
                    rows
                }
                .frame(height: rowHeight * CGFloat(maxVisibleRows))
            } else {
                rows
            }
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

/// A single project row: status dot, name, badge, window count, click to focus.
struct ProjectRowView: View {
    let project: VSCodeProject
    let status: ClaudeProjectStatus?
    let onSelect: () -> Void

    @State private var isHovering = false

    private var isWaiting: Bool { status?.state == .waitingInput }

    var body: some View {
        Button(action: onSelect) {
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

                if project.windowCount > 1 {
                    Text("\(project.windowCount)")
                        .font(.system(size: 8.5, weight: .semibold))
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.09), in: Capsule())
                        .foregroundStyle(PanelTheme.secondaryText)
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
        .buttonStyle(.plain)
        .disabled(project.path == nil)
        .onHover { isHovering = $0 }
        .help(tooltip)
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
        if let status { lines.append(status.tooltip) }
        return lines.joined(separator: "\n\n")
    }
}
