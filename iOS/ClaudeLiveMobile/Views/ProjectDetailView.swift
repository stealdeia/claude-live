import SwiftUI
import ClaudeLiveKit

/// One project, chat by chat.
struct ProjectDetailView: View {
    let project: ClaudeProjectStatus
    let sessions: [ClaudeSessionStatus]
    let inFlight: Set<String>
    let onDecide: (ClaudeSessionStatus, Bool, Bool) -> Void

    var body: some View {
        ZStack {
            ThemedBackground()
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(sessions) { session in
                        NavigationLink {
                            ChatDetailView(
                                session: session,
                                isInFlight: inFlight.contains(session.id),
                                onDecide: onDecide
                            )
                        } label: {
                            GlassCard {
                                chatRow(session)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Text(project.projectPath)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle((project.projectPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func chatRow(_ session: ClaudeSessionStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                StatusDot(state: session.state, isStale: session.isStale)
                Text(session.chatLabel)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(Format.age(since: session.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }

            Text(session.activityLabel)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One chat: what it is doing, and what Claude last said.
struct ChatDetailView: View {
    let session: ClaudeSessionStatus
    let isInFlight: Bool
    let onDecide: (ClaudeSessionStatus, Bool, Bool) -> Void

    var body: some View {
        ZStack {
            ThemedBackground()
            ScrollView {
                VStack(spacing: 14) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: session.state.symbol)
                                    .foregroundStyle(session.state.tint)
                                Text(session.state.label)
                                    .font(.headline)
                                Spacer()
                            }
                            Text(session.activityLabel)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.7))
                            Text("aggiornato \(Format.age(since: session.updatedAt))")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if session.isDecidable {
                        GlassCard {
                            PendingDecisionCard(
                                session: session,
                                isInFlight: isInFlight,
                                onDecide: onDecide
                            )
                        }
                    }

                    message
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle(session.chatLabel)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// What Claude wrote — or an honest note that we cannot read it yet.
    ///
    /// The empty state says *why* it is empty. "Nothing here" would be read as
    /// "Claude said nothing", which is a different and wrong fact.
    @ViewBuilder
    private var message: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Ultimo messaggio di Claude", systemImage: "quote.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))

                if let text = session.lastMessage {
                    Text(text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Il Mac non legge ancora il testo delle conversazioni, quindi qui non c'è nulla da mostrare — non significa che Claude non abbia scritto.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

#Preview("Progetto") {
    let snapshot = RemoteSnapshot.sample(now: Date())
    return NavigationStack {
        ProjectDetailView(
            project: snapshot.projects[0],
            sessions: snapshot.sessions.filter { $0.projectPath == snapshot.projects[0].projectPath },
            inFlight: [],
            onDecide: { _, _, _ in }
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Chat") {
    NavigationStack {
        ChatDetailView(
            session: RemoteSnapshot.sample(now: Date()).sessions[0],
            isInFlight: false,
            onDecide: { _, _, _ in }
        )
    }
    .preferredColorScheme(.dark)
}
