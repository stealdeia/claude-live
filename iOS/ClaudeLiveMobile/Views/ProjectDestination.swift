import SwiftUI
import ClaudeLiveKit

/// Dove porta il tocco su un progetto.
///
/// Con una chat sola porta dentro quella chat, non all'elenco: un elenco di una
/// riga è una schermata da attraversare ogni volta per arrivare all'unico posto
/// dove si voleva andare. Con più chat l'elenco serve, perché c'è da scegliere.
///
/// Sta in un file suo perché la regola vale in due punti — la Home e la scheda
/// dei progetti — e scritta due volte divergerebbe alla prima modifica.
@ViewBuilder
func projectDestination(
    project: ClaudeProjectStatus,
    sessions: [ClaudeSessionStatus],
    inFlight: Set<String>,
    messages: [String: [ClaudeMessage]],
    questions: [String: [ClaudeQuestion]],
    onDecide: @escaping (ClaudeSessionStatus, Bool, Bool) -> Void,
    onAnswer: @escaping (ClaudeSessionStatus, [String: String]) -> Void,
    onPrompt: @escaping (ClaudeSessionStatus, String) -> Void
) -> some View {
    if sessions.count == 1, let only = sessions.first {
        ChatDetailView(
            session: only,
            isInFlight: inFlight.contains(only.id),
            messages: messages[only.sessionID] ?? [],
            questions: questions[only.sessionID] ?? [],
            onDecide: onDecide,
            onAnswer: onAnswer,
            onPrompt: onPrompt
        )
    } else {
        ProjectDetailView(
            project: project,
            sessions: sessions,
            inFlight: inFlight,
            messages: messages,
            questions: questions,
            onDecide: onDecide,
            onAnswer: onAnswer,
            onPrompt: onPrompt
        )
    }
}

/// Le chat di un progetto, la più urgente per prima.
///
/// Era un metodo privato della scheda dei progetti: da quando anche la Home
/// porta dentro un progetto serve a due chiamanti, e due copie divergerebbero
/// alla prima modifica dell'ordinamento.
func sessions(of project: ClaudeProjectStatus, in snapshot: RemoteSnapshot) -> [ClaudeSessionStatus] {
    snapshot.sessions
        .filter { $0.projectPath == project.projectPath }
        .sorted { $0.state == $1.state ? $0.updatedAt > $1.updatedAt : $0.state > $1.state }
}
