import ActivityKit
import Foundation
import ClaudeLiveKit

/// Avvia, aggiorna e chiude la Live Activity.
///
/// ## Cosa fa e cosa non fa ancora
///
/// Aggiorna mentre l'app può girare. Un'attività che continui a cambiare con
/// l'app chiusa ha bisogno di notifiche di tipo `liveactivity`, che sono la
/// seconda metà del lavoro: il token esiste (`pushToken`), il relay non lo
/// riceve ancora. Finché è così, l'isola resta ferma sull'ultimo valore letto,
/// che è comunque meglio di niente — è il conto alla rovescia dei limiti a
/// muoversi da sé, perché quello lo tiene il sistema.
///
/// Non chiude l'attività quando l'app va in sottofondo, ed è il punto: l'isola
/// serve *mentre* si fa altro. La chiude solo chi la spegne, o il sistema dopo
/// otto ore.
@MainActor
final class LiveActivityController: ObservableObject {
    /// Se l'utente la vuole. Accesa: chi installa l'app la installa per sapere
    /// cosa succede senza aprirla, ed è esattamente ciò che questa fa.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Key.enabled)
            if !enabled { Task { await stop() } }
        }
    }

    /// Perché non si vede, quando non si vede. Le Live Activity si possono
    /// spegnere dalle impostazioni di iOS, e senza questo messaggio l'interruttore
    /// dell'app resterebbe acceso su una cosa che non compare.
    @Published private(set) var problem: String?

    private var activity: Activity<ClaudeActivityAttributes>?

    private enum Key { static let enabled = "activity.enabled" }

    init() {
        enabled = UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true
        // Un'attività può essere sopravvissuta a un riavvio dell'app: si riprende
        // quella invece di chiederne una seconda, che il sistema mostrerebbe
        // accanto alla prima.
        activity = Activity<ClaudeActivityAttributes>.activities.first
    }

    /// Porta l'isola in pari con quello che il Mac ha detto.
    func sync(with snapshot: RemoteSnapshot?) async {
        guard enabled else { return }
        guard let snapshot else { return }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            problem = "Le attività in tempo reale sono spente nelle impostazioni di iOS."
            return
        }
        problem = nil

        let state = Self.state(from: snapshot)

        if let activity {
            await activity.update(ActivityContent(state: state, staleDate: nil))
            return
        }

        do {
            activity = try Activity.request(
                attributes: ClaudeActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil),
                // Nessun tipo di notifica per ora: finché il relay non manda
                // aggiornamenti, chiedere `.token` produrrebbe un token che
                // nessuno usa.
                pushType: nil
            )
        } catch {
            problem = "Non sono riuscito ad avviare l'attività: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }

    // MARK: - Da fotografia a contenuto

    /// Cosa dell'intera fotografia finisce nell'isola.
    ///
    /// Poco, e scelto: nello spazio dell'isola una cosa in più è una cosa in meno
    /// leggibile. I due contatori perché sono il motivo per cui si guarda là, e
    /// **un** progetto — quello che chiede attenzione — perché elencarli tutti
    /// vorrebbe dire non leggerne nessuno.
    static func state(from snapshot: RemoteSnapshot) -> ClaudeActivityAttributes.ContentState {
        // Il progetto di cui parlare: quello dell'avviso se c'è, altrimenti il
        // primo, che arriva già ordinato per urgenza dal Mac.
        let project = snapshot.alert?.projectName
            ?? snapshot.projects.first.map { ($0.projectPath as NSString).lastPathComponent }

        let session = snapshot.sessions.first { $0.isDecidable }
        let pending: String? = {
            guard let session else { return nil }
            if let asked = snapshot.questions?[session.sessionID]?.first {
                return asked.question
            }
            return session.toolSummary
        }()

        return ClaudeActivityAttributes.ContentState(
            fiveHourPercent: snapshot.usage?.fiveHour?.percent,
            fiveHourResetsAt: snapshot.usage?.fiveHour?.resetAt,
            sevenDayPercent: snapshot.usage?.sevenDay?.percent,
            sevenDayResetsAt: snapshot.usage?.sevenDay?.resetAt,
            projectName: project,
            stateLabel: snapshot.projects.first?.state.label,
            alertKind: snapshot.alert?.kind.rawValue,
            pending: pending,
            updatedAt: snapshot.generatedAt
        )
    }
}
