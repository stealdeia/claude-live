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
            await activity.update(Self.content(state))
            return
        }

        do {
            activity = try Activity.request(
                attributes: ClaudeActivityAttributes(),
                content: Self.content(state),
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

    /// Il contenuto, con una data di scadenza.
    ///
    /// La scadenza è la risposta onesta a una domanda che il sistema pone e noi
    /// no: un'attività continua a essere disegnata anche quando l'app non gira
    /// più — è un altro processo — quindi i numeri potrebbero essere di ore
    /// prima. Passata questa data iOS la mostra sbiadita, cioè dice da sé «questi
    /// dati sono vecchi» invece di lasciar credere che siano di adesso.
    ///
    /// Dieci minuti: il Mac pubblica almeno una volta al minuto quando è vivo,
    /// quindi dieci minuti di silenzio significano che non lo è.
    private static func content(
        _ state: ClaudeActivityAttributes.ContentState
    ) -> ActivityContent<ClaudeActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: state.updatedAt.addingTimeInterval(600))
    }

    // MARK: - Da fotografia a contenuto

    /// Cosa dell'intera fotografia finisce nell'isola.
    ///
    /// Poco, e scelto: nello spazio dell'isola una cosa in più è una cosa in meno
    /// leggibile. I due contatori perché sono il motivo per cui si guarda là, e
    /// **tre** progetti perché tre righe è quanto ci sta — arrivano già ordinati
    /// per urgenza, quindi i tre mostrati sono i tre che contano.
    static func state(from snapshot: RemoteSnapshot) -> ClaudeActivityAttributes.ContentState {
        let alertPath = snapshot.alert?.projectPath

        let projects = snapshot.projects.prefix(3).map { project in
            ClaudeActivityAttributes.ContentState.Project(
                name: (project.projectPath as NSString).lastPathComponent,
                state: project.state,
                alerting: project.projectPath == alertPath
            )
        }

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
            projects: Array(projects),
            // La chat da aprire: quella della richiesta in attesa se c'è,
            // altrimenti quella nominata dall'avviso. Toccando l'isola si
            // finisce dove c'è qualcosa da fare, non nella schermata iniziale.
            alertSessionID: session?.sessionID ?? snapshot.alert?.sessionID,
            alertKind: snapshot.alert?.kind.rawValue,
            pending: pending,
            updatedAt: snapshot.generatedAt
        )
    }
}
