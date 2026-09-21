import Combine
import Foundation
import ClaudeLiveKit
import MascotCore

/// Porta quello che si scrive nella barra dove ha senso che vada.
///
/// È l'altro punto di contatto fra la mascotte e Claude Code, e sta qui per lo
/// stesso motivo per cui `ClaudeMascotEventSource` sta dov'è: la mascotte non
/// deve sapere cosa sia una sessione, e lo `ClaudeStatusStore` non deve sapere
/// che esiste una mascotte.
///
/// ## Le due strade
///
/// Scrivere dentro una conversazione viva di Claude Code si può fare solo nei
/// momenti in cui un hook è fermo e ci sta ascoltando:
///
///   * **subito**, quando l'hook sta già aspettando qualcosa — una domanda a cui
///     rispondere, o la fine di un turno trattenuta perché sei lontano dal Mac;
///   * **a fine turno**, lasciando il messaggio in una cartella che l'hook
///     guarda quando Claude smette di lavorare. È l'unica strada che funziona
///     stando al Mac, ed è per questo che la barra, stando al Mac, quasi sempre
///     mette in coda invece di mandare.
///
/// Non esiste una terza strada che non passi dal fingere di essere una tastiera.
@MainActor
final class MascotPromptRouter: ObservableObject {
    /// A chi parla la barra adesso.
    @Published private(set) var target: MascotPromptTarget = .none
    /// Quello che è già in coda per il bersaglio, se c'è.
    @Published private(set) var queued: String?

    /// Com'è andata, in una frase da mostrare sotto la barra.
    enum Outcome: Equatable {
        case sent(String)
        case queued(String)
        case refused(String)
    }

    private let status: ClaudeStatusStore
    private var cancellables: Set<AnyCancellable> = []
    private var queueWatcher: DirectoryWatcher?

    init(status: ClaudeStatusStore) {
        self.status = status

        Publishers.CombineLatest3(
            status.$sessionsByPath, status.$waitingSessions, status.$pendingQuestions
        )
        .sink { [weak self] _, _, _ in
            Task { @MainActor in self?.refresh() }
        }
        .store(in: &cancellables)

        // La coda la svuota l'hook, non noi: senza guardare la cartella, la
        // barra continuerebbe a dire «in coda» per un messaggio già consegnato.
        Paths.ensureStatusDirectory()
        queueWatcher = DirectoryWatcher(url: Paths.queueDirectory) { [weak self] in
            Task { @MainActor in self?.refreshQueued() }
        }
        queueWatcher?.start()

        refresh()
    }

    deinit {
        queueWatcher?.stop()
    }

    // MARK: - Chi ascolta

    private func refresh() {
        let questions = status.pendingQuestions
        let waiting = Set(status.waitingSessions.filter(\.isDecidable).map(\.sessionID))

        let candidates = status.sessionsByPath.values.flatMap { $0 }.map { session in
            MascotPromptCandidate(
                sessionID: session.sessionID,
                projectName: session.projectName,
                isWorking: session.state == .working,
                acceptsFollowUp: session.acceptsPrompt,
                pendingQuestion: questions[session.sessionID]?.first?.question,
                awaitingPermission: waiting.contains(session.sessionID),
                updatedAt: session.updatedAt
            )
        }

        let resolved = MascotPromptRouting.target(among: candidates)
        if resolved != target { target = resolved }
        refreshQueued()
    }

    private func refreshQueued() {
        guard let sessionID = target.sessionID else {
            if queued != nil { queued = nil }
            return
        }
        let text = readQueued(forSession: sessionID)
        if text != queued { queued = text }
    }

    private func queueURL(forSession sessionID: String) -> URL {
        Paths.queueDirectory.appendingPathComponent(
            MascotPromptRouting.queueFileName(forSession: sessionID)
        )
    }

    private func readQueued(forSession sessionID: String) -> String? {
        guard let data = try? Data(contentsOf: queueURL(forSession: sessionID)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["prompt"] as? String,
              !text.isEmpty
        else { return nil }
        return text
    }

    // MARK: - Mandare

    @discardableResult
    func send(_ raw: String) -> Outcome {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .refused("Non c'è niente da mandare") }

        switch target {
        case .question(let sessionID, let project, let question):
            guard let session = session(withID: sessionID) else {
                return .refused("La domanda non aspetta più")
            }
            status.answer(session, answers: [question: text])
            return .sent("Risposto a \(project)")

        case .followUp(let sessionID, let project):
            guard let session = session(withID: sessionID), session.acceptsPrompt else {
                return .refused("La chat non aspetta più un seguito")
            }
            status.prompt(session, text: text)
            return .sent("Mandato a \(project)")

        case .queue(let sessionID, let project):
            guard enqueue(text, forSession: sessionID) else {
                return .refused("Non sono riuscito a metterlo in coda")
            }
            queued = text
            Log.info("In coda per «\(project)»: \(text.prefix(80))", category: .mascot)
            return .queued("Parte quando \(project) ha finito")

        case .permission(let project):
            return .refused("\(project) chiede un permesso: rispondi dal pannello")

        case .none:
            return .refused("Nessuna chat a cui scrivere")
        }
    }

    /// Toglie dalla coda il messaggio non ancora consegnato.
    func cancelQueued() {
        guard let sessionID = target.sessionID else { return }
        try? FileManager.default.removeItem(at: queueURL(forSession: sessionID))
        queued = nil
        Log.info("Messaggio tolto dalla coda", category: .mascot)
    }

    /// Scrive il messaggio dove l'hook lo troverà a fine turno.
    ///
    /// Stessa forma dei file delle decisioni — un oggetto JSON con il testo — più
    /// l'ora in cui è stato scritto, che è ciò che permette all'hook di buttare
    /// via un messaggio di mezz'ora fa invece di infilarlo in una conversazione
    /// che nel frattempo è andata da un'altra parte.
    private func enqueue(_ text: String, forSession sessionID: String) -> Bool {
        Paths.ensureStatusDirectory()
        let payload: [String: Any] = [
            "prompt": text,
            "at": Date().timeIntervalSince1970,
            "session_id": sessionID,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        do {
            try data.write(to: queueURL(forSession: sessionID), options: .atomic)
            return true
        } catch {
            Log.error("Coda non scritta: \(error.localizedDescription)", category: .mascot)
            return false
        }
    }

    private func session(withID id: String) -> ClaudeSessionStatus? {
        status.sessionsByPath.values.flatMap { $0 }.first { $0.sessionID == id }
    }
}

private extension MascotPromptTarget {
    var sessionID: String? {
        switch self {
        case .question(let id, _, _), .followUp(let id, _), .queue(let id, _):
            return id
        case .permission, .none:
            return nil
        }
    }
}
