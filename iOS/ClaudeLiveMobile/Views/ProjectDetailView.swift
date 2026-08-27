import SwiftUI
import ClaudeLiveKit

/// One project, chat by chat.
struct ProjectDetailView: View {
    let project: ClaudeProjectStatus
    let sessions: [ClaudeSessionStatus]
    let inFlight: Set<String>

    /// Gli ultimi messaggi di ogni conversazione, per identificativo di sessione.
    /// Vuoto se il Mac è più vecchio di questa versione dell'app.
    let messages: [String: [ClaudeMessage]]
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
                                messages: messages[session.sessionID] ?? [],
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

    /// Gli ultimi messaggi leggibili, dal più vecchio al più recente.
    let messages: [ClaudeMessage]
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

                    conversation
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle(session.chatLabel)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Gli ultimi messaggi della conversazione.
    ///
    /// Il riquadro vuoto spiega *perché* è vuoto. «Niente qui» verrebbe letto
    /// come «Claude non ha detto niente», che è un fatto diverso e sbagliato — e
    /// per un pezzo di tempo è stato il caso: il Mac non leggeva le trascrizioni.
    @ViewBuilder
    private var conversation: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Ultimi messaggi", systemImage: "quote.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))

                if messages.isEmpty {
                    Text(emptyExplanation)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                        bubble(message)
                    }
                }
            }
        }
    }

    /// Vuoto per due motivi diversi, e dirlo male sarebbe peggio che tacere: una
    /// chat può non avere ancora parole (solo lavoro con gli strumenti), oppure
    /// il Mac può essere una versione che non li manda.
    private var emptyExplanation: String {
        session.lastMessage
            ?? "Di questa conversazione non c'è ancora niente da leggere: può contenere solo lavoro con gli strumenti, oppure il Mac non l'ha ancora pubblicata. Non vuol dire che Claude non abbia scritto."
    }

    private func bubble(_ message: ClaudeMessage) -> some View {
        let mine = message.author == .user
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: mine ? "person.fill" : "sparkle")
                    .font(.system(size: 9))
                Text(mine ? "Tu" : "Claude")
                    .font(.caption2.weight(.semibold))
                if let at = message.at {
                    Text("· \(Format.age(since: at))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer(minLength: 2)
            }
            .foregroundStyle(mine ? .white.opacity(0.6) : GlowRGB.done.color.opacity(0.8))

            Text(message.text)
                .font(.footnote)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(mine ? 0.06 : 0.10))
        )
    }
}

#Preview("Progetto") {
    let snapshot = RemoteSnapshot.sample(now: Date())
    return NavigationStack {
        ProjectDetailView(
            project: snapshot.projects[0],
            sessions: snapshot.sessions.filter { $0.projectPath == snapshot.projects[0].projectPath },
            inFlight: [],
            messages: snapshot.messages ?? [:],
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
            messages: [
                ClaudeMessage(author: .user, text: "Sistemami il pannello.", at: Date()),
                ClaudeMessage(author: .assistant, text: "Fatto: era una variabile sovrascritta.", at: Date()),
            ],
            onDecide: { _, _, _ in }
        )
    }
    .preferredColorScheme(.dark)
}
