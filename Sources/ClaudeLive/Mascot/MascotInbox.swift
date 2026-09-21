import Combine
import Foundation
import ClaudeLiveKit
import MascotCore

/// Le cose successe e non ancora viste.
///
/// È la stessa nozione che accende la striscia luminosa attorno al notch — un
/// avviso per progetto, che resta finché non lo si guarda — vista dalla parte
/// della mascotte: il pallino sulla testa dice *quanti* sono, il fumetto dice
/// *quali*, e i pulsanti dentro al fumetto permettono di rispondere senza
/// andare a cercare la finestra giusta.
///
/// Terzo adattatore fra la mascotte e Claude Code, e l'ultimo: gli eventi
/// (`ClaudeMascotEventSource`) dicono *è successo qualcosa adesso*, il router
/// (`MascotPromptRouter`) dice *dove va quello che scrivi*, questo dice *cosa è
/// rimasto in sospeso*. La mascotte continua a non sapere cosa sia un progetto.
@MainActor
final class MascotInbox: ObservableObject {
    struct Item: Identifiable, Equatable {
        /// Il percorso del progetto: un avviso per progetto, come nel pannello.
        let id: String
        let project: String
        let kind: MascotNotice.Kind
        let detail: String?
        let at: Date
        /// La sessione che sta aspettando, quando c'è qualcosa da risponderle.
        let sessionID: String?
        /// Le opzioni fra cui scegliere, se Claude ha fatto una domanda.
        let questions: [ClaudeQuestion]
        /// Un permesso da consentire o negare.
        let decidable: Bool

        /// Se si può rispondere da qui, senza andare nel progetto.
        var isAnswerable: Bool { decidable || !questions.isEmpty }
    }

    @Published private(set) var items: [Item] = []

    private let status: ClaudeStatusStore
    private let onFocusProject: (String) -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(status: ClaudeStatusStore, onFocusProject: @escaping (String) -> Void) {
        self.status = status
        self.onFocusProject = onFocusProject

        Publishers.CombineLatest3(
            status.$alerts, status.$waitingSessions, status.$pendingQuestions
        )
        .sink { [weak self] _, _, _ in
            Task { @MainActor in self?.refresh() }
        }
        .store(in: &cancellables)

        refresh()
    }

    private func refresh() {
        let waiting = status.waitingSessions
        let questions = status.pendingQuestions

        let rebuilt = status.alerts.values
            .map { alert -> Item in
                // La sessione in attesa dentro quel progetto, se c'è: è lei che
                // porta la domanda e l'identificativo a cui rispondere.
                let session = waiting.first { $0.projectPath == alert.projectPath }
                return Item(
                    id: alert.projectPath,
                    project: alert.projectName,
                    kind: Self.kind(for: alert.kind),
                    detail: alert.detail,
                    at: alert.raisedAt,
                    sessionID: session?.sessionID ?? alert.sessionID,
                    questions: session.flatMap { questions[$0.sessionID] } ?? [],
                    decidable: session?.isDecidable ?? false
                )
            }
            // Più urgente prima, poi più recente: lo stesso ordine del pannello,
            // perché è lo stesso elenco visto da un'altra parte.
            .sorted { lhs, rhs in
                lhs.kind.urgency == rhs.kind.urgency ? lhs.at > rhs.at : lhs.kind.urgency > rhs.kind.urgency
            }

        guard rebuilt != items else { return }
        items = rebuilt
    }

    // MARK: - Cosa si può fare

    /// Porta avanti il progetto e spegne l'avviso: è il gesto «l'ho visto».
    func open(_ item: Item) {
        onFocusProject(item.id)
        status.clearAlert(forPath: item.id)
    }

    func dismiss(_ item: Item) {
        status.clearAlert(forPath: item.id)
    }

    func dismissAll() {
        status.clearAllAlerts()
    }

    /// Consente o nega un permesso, come i pulsanti del pannello.
    func decide(_ item: Item, allow: Bool) {
        guard let session = session(for: item) else { return }
        status.decide(session, allow: allow, remember: false)
        status.clearAlert(forPath: item.id)
    }

    /// Sceglie una delle opzioni di una domanda.
    ///
    /// L'etichetta va rimandata **alla lettera**: Claude Code riconosce la
    /// risposta confrontandola con le opzioni che ha proposto, e una parola
    /// cambiata la fa passare per una risposta scritta a mano. Vedi
    /// `ClaudeQuestion.Option`.
    func answer(_ item: Item, question: ClaudeQuestion, label: String) {
        guard let session = session(for: item) else { return }
        status.answer(session, answers: [question.question: label])
        status.clearAlert(forPath: item.id)
    }

    private func session(for item: Item) -> ClaudeSessionStatus? {
        guard let id = item.sessionID else { return nil }
        return status.waitingSessions.first { $0.sessionID == id }
    }

    private static func kind(for kind: ClaudeAlertKind) -> MascotNotice.Kind {
        switch kind {
        case .done: return .finished
        case .waiting: return .needsYou
        case .failed: return .failed
        }
    }
}

extension MascotNotice.Kind {
    /// Quale vince quando ce n'è più di uno: lo stesso ordine di
    /// `ClaudeAlertKind.urgency`, perché è lo stesso giudizio.
    var urgency: Int {
        switch self {
        case .failed: return 3
        case .needsYou: return 2
        case .finished: return 1
        }
    }
}
