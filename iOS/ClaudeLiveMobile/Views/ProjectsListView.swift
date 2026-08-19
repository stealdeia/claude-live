import SwiftUI
import ClaudeLiveKit

/// The projects, and their chats underneath when there is more than one.
///
/// Same rule as the Mac panel: a project with a single chat says nothing extra,
/// because the project row is already telling you about that chat. Chats appear
/// only when there are two or more and the distinction starts to matter.
struct ProjectsListView: View {
    let projects: [ClaudeProjectStatus]
    let sessions: [ClaudeSessionStatus]
    /// The session the current alert was raised by, lit so the eye lands on the
    /// chat that changed instead of the project that contains it.
    let highlightedSessionID: String?

    var body: some View {
        SectionCard(title: "Progetti", subtitle: projects.isEmpty ? nil : "\(projects.count)") {
            if projects.isEmpty {
                Text("Nessuna sessione di Claude Code aperta.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(projects, id: \.projectPath) { project in
                        projectRow(project)
                        let chats = self.chats(of: project)
                        if chats.count > 1 {
                            ForEach(chats) { chatRow($0) }
                        }
                        if project.projectPath != projects.last?.projectPath {
                            Divider().padding(.vertical, 8)
                        }
                    }
                }
            }
        }
    }

    private func chats(of project: ClaudeProjectStatus) -> [ClaudeSessionStatus] {
        sessions
            .filter { $0.projectPath == project.projectPath }
            .sorted { $0.state == $1.state ? $0.updatedAt > $1.updatedAt : $0.state > $1.state }
    }

    private func projectRow(_ project: ClaudeProjectStatus) -> some View {
        HStack(spacing: 10) {
            StatusDot(state: project.state, isStale: project.isStale, size: 11)

            Text((project.projectPath as NSString).lastPathComponent)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if let badge = project.badge {
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(project.state.tint.opacity(0.18), in: Capsule())
            }

            Spacer(minLength: 6)

            if project.sessionCount > 1 {
                Label("\(project.sessionCount)", systemImage: "text.bubble")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            Text(Format.age(since: project.updatedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }

    private func chatRow(_ session: ClaudeSessionStatus) -> some View {
        HStack(spacing: 9) {
            StatusDot(state: session.state, isStale: session.isStale, size: 7)
            Text(session.chatLabel)
                .font(.caption)
                .lineLimit(1)
            Text("·")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(session.activityLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(Format.age(since: session.updatedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 21)
        .padding(.vertical, 3)
        .background {
            if session.sessionID == highlightedSessionID {
                RoundedRectangle(cornerRadius: 6)
                    .fill(session.state.tint.opacity(0.14))
            }
        }
    }
}

#Preview("Progetti") {
    let snapshot = RemoteSnapshot.sample()
    return ScrollView {
        ProjectsListView(
            projects: snapshot.projects,
            sessions: snapshot.sessions,
            highlightedSessionID: snapshot.alert?.sessionID
        )
        .padding()
    }
    .background(.background.tertiary)
}

#Preview("Nessun progetto") {
    ScrollView {
        ProjectsListView(projects: [], sessions: [], highlightedSessionID: nil)
            .padding()
    }
    .background(.background.tertiary)
}
