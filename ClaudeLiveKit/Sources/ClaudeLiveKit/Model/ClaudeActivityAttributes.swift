#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// Cosa mostra la Live Activity: l'isola dinamica e la schermata di blocco.
///
/// Sta nel pacchetto condiviso perché deve essere lo stesso tipo per due
/// bersagli — l'app che avvia l'attività e l'estensione che la disegna — e due
/// definizioni che devono combaciare byte per byte non possono essere due
/// definizioni. Su macOS non esiste: `ActivityKit` è solo iOS, e il `canImport`
/// qui sopra è ciò che permette al Mac di compilare lo stesso pacchetto.
///
/// ## Perché così poco
///
/// Il contenuto viaggia dentro una notifica quando l'attività si aggiorna da
/// remota, e una notifica è visibile ad Apple e al relay. Quindi qui ci sono i
/// numeri dell'utilizzo — che non dicono niente di nessuno — e lo stato; il nome
/// del progetto c'è perché senza di esso l'isola direbbe «un progetto chiede
/// qualcosa» e non servirebbe a niente, ma è la sola cosa identificativa, ed è
/// una scelta da rivedere quando gli aggiornamenti arriveranno via notifica.
public struct ClaudeActivityAttributes: ActivityAttributes {
    /// Ciò che cambia mentre l'attività vive.
    public struct ContentState: Codable, Hashable {
        /// Percentuale della finestra di cinque ore, 0-100.
        public var fiveHourPercent: Double?
        /// Quando quella finestra si azzera, per il conto alla rovescia.
        public var fiveHourResetsAt: Date?

        public var sevenDayPercent: Double?
        public var sevenDayResetsAt: Date?

        /// Il progetto che chiede attenzione, se ce n'è uno.
        public var projectName: String?
        /// Come sta: «al lavoro», «in attesa», «finito».
        public var stateLabel: String?

        /// Il tipo di avviso in corso, per colorare il filo attorno all'isola.
        /// Il valore grezzo di `ClaudeAlertKind`, così un tipo aggiunto in
        /// futuro non fa fallire la decodifica di un'attività già in corso.
        public var alertKind: String?

        /// La domanda o il permesso in attesa, in una riga.
        public var pending: String?

        /// Quando il Mac ha detto queste cose. Serve a dire «un minuto fa»
        /// invece di far credere che siano di adesso.
        public var updatedAt: Date

        public init(
            fiveHourPercent: Double? = nil,
            fiveHourResetsAt: Date? = nil,
            sevenDayPercent: Double? = nil,
            sevenDayResetsAt: Date? = nil,
            projectName: String? = nil,
            stateLabel: String? = nil,
            alertKind: String? = nil,
            pending: String? = nil,
            updatedAt: Date = Date()
        ) {
            self.fiveHourPercent = fiveHourPercent
            self.fiveHourResetsAt = fiveHourResetsAt
            self.sevenDayPercent = sevenDayPercent
            self.sevenDayResetsAt = sevenDayResetsAt
            self.projectName = projectName
            self.stateLabel = stateLabel
            self.alertKind = alertKind
            self.pending = pending
            self.updatedAt = updatedAt
        }

        /// Il tipo di avviso, se è uno che questa versione conosce.
        public var alert: ClaudeAlertKind? {
            alertKind.flatMap(ClaudeAlertKind.init(rawValue:))
        }
    }

    /// Fisso per tutta la vita dell'attività: serve solo a distinguere una
    /// sessione dell'attività dalla successiva.
    public var startedAt: Date

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }
}
#endif
