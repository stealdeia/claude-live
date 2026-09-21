import Combine
import Foundation
import ClaudeLiveKit
import MascotCore

/// Da dove la mascotte prende le notizie.
///
/// Un protocollo con dentro una cosa sola perché serve a separare, non ad
/// astrarre: la mascotte guarda *questo*, e chi le racconta i fatti può essere
/// il vero stato di Claude Code, un finto per una prova, o domani qualcosa che
/// oggi non esiste.
/// Isolato al thread principale come tutto il resto della mascotte: gli eventi
/// finiscono in una macchina a stati che comanda delle finestre.
@MainActor
protocol MascotEventSource {
    var events: AnyPublisher<MascotEvent, Never> { get }
}

/// Il canale interno degli eventi.
///
/// Serve a rendere banale aggiungere un motivo per far reagire il personaggio:
/// da qualunque punto dell'app, una riga —
/// `MascotEventBus.shared.post(.notice(.failed))` — e il pupazzetto se ne
/// accorge. Chi la scrive non ha bisogno di sapere che esiste una macchina a
/// stati, né di avere in mano il controller della mascotte.
@MainActor
final class MascotEventBus: MascotEventSource {
    static let shared = MascotEventBus()

    private let subject = PassthroughSubject<MascotEvent, Never>()

    var events: AnyPublisher<MascotEvent, Never> { subject.eraseToAnyPublisher() }

    func post(_ event: MascotEvent) {
        Log.debug("Evento mascotte: \(event)", category: .mascot)
        subject.send(event)
    }
}

/// Traduce quello che Claude Code sta facendo in notizie per la mascotte.
///
/// Sta qui, e non dentro la mascotte, tutto ciò che sa di progetti, sessioni e
/// avvisi: è l'unico punto in cui i due mondi si toccano. La mascotte non
/// importa `ClaudeStatusStore`, e `ClaudeStatusStore` non sa che esiste una
/// mascotte — che è ciò che permette di aggiungere un trigger, o di togliere del
/// tutto la funzione, senza rimettere le mani nella logica dell'app.
///
/// Guarda le stesse due cose che guarda la striscia luminosa attorno al notch,
/// per la stessa ragione per cui le guarda lei: gli **avvisi** sono fatti appena
/// successi (un turno finito, un permesso chiesto, un errore), mentre lo **stato
/// dei progetti** dice se c'è del lavoro in corso adesso.
@MainActor
final class ClaudeMascotEventSource {
    private let status: ClaudeStatusStore
    private let bus: MascotEventBus
    private var cancellables: Set<AnyCancellable> = []

    /// Quando è stato alzato l'ultimo avviso già raccontato, per progetto.
    ///
    /// Senza questo la mascotte salterebbe a ogni *cambiamento* dell'elenco
    /// degli avvisi — compreso uno spegnimento — invece che a ogni avviso nuovo.
    private var announced: [String: Date] = [:]
    private var wasWorking = false

    /// Il canale è un parametro — e vale `nil` per dire «quello di sempre» —
    /// perché un valore predefinito che nomina un singoletto isolato al thread
    /// principale non è scrivibile senza farsi dire dal compilatore che un
    /// giorno sarà un errore.
    init(status: ClaudeStatusStore, bus: MascotEventBus? = nil) {
        self.status = status
        self.bus = bus ?? .shared

        status.$alerts
            .sink { [weak self] alerts in
                Task { @MainActor in self?.announce(alerts) }
            }
            .store(in: &cancellables)

        status.$statusesByPath
            .map { statuses in statuses.values.contains { $0.state == .working } }
            .removeDuplicates()
            .sink { [weak self] isWorking in
                Task { @MainActor in self?.report(isWorking: isWorking) }
            }
            .store(in: &cancellables)
    }

    private func announce(_ alerts: [String: ClaudeAlert]) {
        for (path, alert) in alerts where announced[path] != alert.raisedAt {
            announced[path] = alert.raisedAt
            bus.post(.notice(MascotNotice(
                kind: Self.kind(for: alert.kind),
                project: alert.projectName,
                detail: alert.detail
            )))
        }
        // I progetti spariti non devono restare in memoria per sempre, e un
        // avviso che torna dopo essere stato spento è una notizia nuova.
        announced = announced.filter { alerts[$0.key] != nil }
    }

    private func report(isWorking: Bool) {
        guard isWorking != wasWorking else { return }
        wasWorking = isWorking
        bus.post(.working(isWorking))
    }

    /// L'unico punto in cui i fatti di Claude Code diventano espressioni del
    /// personaggio.
    private static func kind(for kind: ClaudeAlertKind) -> MascotNotice.Kind {
        switch kind {
        case .done: return .finished
        case .waiting: return .needsYou
        case .failed: return .failed
        }
    }
}
