import ActivityKit
import Foundation
import ClaudeLiveKit

/// Avvia, aggiorna e chiude la Live Activity.
///
/// ## Chi la aggiorna
///
/// Due strade, e servono entrambe.
///
/// Mentre l'app gira, aggiorna lei: il contenuto va in chiaro dentro l'attività,
/// perché sta parlando a se stessa.
///
/// Quando l'app non gira — e «non gira» comprende anche «è in sottofondo», perché
/// iOS la sospende entro pochi secondi da quando passi a un'altra app —
/// l'aggiornamento deve arrivare come notifica. Per quello serve un token, che
/// ActivityKit dà per ogni attività e che va consegnato al relay. Il contenuto
/// che passa da là è **sigillato**: il relay lo trasporta senza poterlo leggere e
/// l'estensione lo apre sul telefono.
///
/// Non chiude l'attività quando l'app va in sottofondo, ed è il punto: l'isola
/// serve *mentre* si fa altro. La chiude chi la spegne, o il sistema dopo otto
/// ore. Sul contenuto c'è una scadenza, così un'isola che non riceve più niente
/// si sbiadisce da sé invece di mostrare numeri vecchi come se fossero di adesso.
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
    private var tokenWatcher: Task<Void, Never>?

    /// Chi porta il token al relay. Iniettato invece di creato qui: il canale
    /// verso il relay è del `RemoteStore`, e due oggetti che parlano allo stesso
    /// indirizzo con due copie delle credenziali sono due cose da tenere in pari.
    private weak var store: RemoteStore?

    private enum Key { static let enabled = "activity.enabled" }

    init() {
        enabled = UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true
        // Un'attività può essere sopravvissuta a un riavvio dell'app: si riprende
        // quella invece di chiederne una seconda, che il sistema mostrerebbe
        // accanto alla prima.
        activity = Activity<ClaudeActivityAttributes>.activities.first
    }

    func attach(to store: RemoteStore) {
        self.store = store
        // La chiave dell'accoppiamento, copiata dove l'estensione può leggerla.
        // Rifatto a ogni avvio: se l'accoppiamento è stato rifatto, la copia
        // vecchia aprirebbe le scatole sbagliate — cioè nessuna.
        if let exported = RemoteSecrets.read(.encryptionKey) {
            IslandKey.share(exported)
        }
        if let existing = activity { watchToken(of: existing) }
    }

    /// Porta l'isola in pari con quello che il Mac ha detto.
    func sync(with snapshot: RemoteSnapshot?) async {
        guard enabled, let snapshot else { return }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            problem = "Le attività in tempo reale sono spente nelle impostazioni di iOS."
            return
        }
        problem = nil

        let island = ClaudeIslandState(snapshot: snapshot)
        let content = Self.content(island)

        if let activity {
            await activity.update(content)
            return
        }

        do {
            let started = try Activity.request(
                attributes: ClaudeActivityAttributes(),
                content: content,
                // Con il token: è quello che permette al relay di aggiornare
                // l'isola quando l'app non gira. Senza, l'isola resterebbe ferma
                // sull'ultimo valore letto mentre usi altre app.
                pushType: .token
            )
            activity = started
            watchToken(of: started)
        } catch {
            problem = "Non sono riuscito ad avviare l'attività: \(error.localizedDescription)"
        }
    }

    func stop() async {
        tokenWatcher?.cancel()
        tokenWatcher = nil
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }

    // MARK: - Il token

    /// Segue il token dell'attività e lo consegna al relay ogni volta che cambia.
    ///
    /// Ogni volta, non una: il sistema può darne uno nuovo mentre l'attività vive,
    /// e un token stantio sul relay è una notifica che Apple accetta e consegna a
    /// nessuno — il guasto più silenzioso che ci sia.
    private func watchToken(of activity: Activity<ClaudeActivityAttributes>) {
        tokenWatcher?.cancel()
        tokenWatcher = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                let hex = token.map { String(format: "%02x", $0) }.joined()
                await self?.store?.sendActivityToken(hex)
            }
        }
    }

    /// Il contenuto, con una data di scadenza.
    ///
    /// La scadenza è la risposta onesta a una domanda che il sistema pone e noi
    /// no: un'attività continua a essere disegnata anche quando l'app non gira —
    /// è un altro processo — quindi i numeri potrebbero essere di ore prima.
    /// Passata questa data iOS la mostra sbiadita, cioè dice da sé «questi dati
    /// sono vecchi» invece di lasciar credere che siano di adesso.
    ///
    /// Dieci minuti: il Mac pubblica almeno una volta al minuto quando è vivo,
    /// quindi dieci minuti di silenzio significano che non lo è.
    private static func content(
        _ island: ClaudeIslandState
    ) -> ActivityContent<ClaudeActivityAttributes.ContentState> {
        ActivityContent(
            state: ClaudeActivityAttributes.ContentState(island: island),
            staleDate: island.updatedAt.addingTimeInterval(600)
        )
    }
}
