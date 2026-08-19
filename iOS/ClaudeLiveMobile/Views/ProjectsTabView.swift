import SwiftUI
import ClaudeLiveKit

/// Everything about the projects, including the requests still unanswered.
///
/// The requests appear here as well as on Home, and that repetition is
/// deliberate: Home shows the one that is blocking something now, this tab is
/// where you come to work through all of them.
struct ProjectsTabView: View {
    let snapshot: RemoteSnapshot?
    let inFlight: Set<String>
    let onDecide: (ClaudeSessionStatus, Bool, Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let snapshot {
                    let decidable = snapshot.sessions.filter(\.isDecidable)
                    if !decidable.isEmpty {
                        VStack(spacing: 12) {
                            sectionTitle("Da approvare")
                            ForEach(decidable) { session in
                                GlassCard {
                                    PendingDecisionCard(
                                        session: session,
                                        isInFlight: inFlight.contains(session.id),
                                        onDecide: onDecide
                                    )
                                }
                            }
                        }
                    }

                    if snapshot.projects.isEmpty {
                        GlassCard {
                            Text("Nessuna sessione di Claude Code aperta.")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        VStack(spacing: 12) {
                            sectionTitle("Progetti")
                            ForEach(snapshot.projects, id: \.projectPath) { project in
                                NavigationLink {
                                    ProjectDetailView(
                                        project: project,
                                        sessions: sessions(of: project, in: snapshot),
                                        inFlight: inFlight,
                                        onDecide: onDecide
                                    )
                                } label: {
                                    GlassCard {
                                        row(project, in: snapshot)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func sessions(of project: ClaudeProjectStatus, in snapshot: RemoteSnapshot) -> [ClaudeSessionStatus] {
        snapshot.sessions
            .filter { $0.projectPath == project.projectPath }
            .sorted { $0.state == $1.state ? $0.updatedAt > $1.updatedAt : $0.state > $1.state }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.75))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ project: ClaudeProjectStatus, in snapshot: RemoteSnapshot) -> some View {
        let chats = sessions(of: project, in: snapshot)
        return VStack(alignment: .leading, spacing: 10) {
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
                        .background(project.state.tint.opacity(0.22), in: Capsule())
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }

            HStack(spacing: 12) {
                Label("\(chats.count)", systemImage: "text.bubble")
                Text(Format.age(since: project.updatedAt))
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
        }
    }
}

#Preview("Progetti") {
    NavigationStack {
        ZStack {
            ThemedBackground()
            ProjectsTabView(
                snapshot: RemoteSnapshot.sample(now: Date()),
                inFlight: [],
                onDecide: { _, _, _ in }
            )
        }
        .navigationTitle("Progetti")
    }
    .preferredColorScheme(.dark)
}
