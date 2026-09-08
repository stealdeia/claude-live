import Foundation

/// Cosa mostra l'isola dinamica, in una forma che anche il Mac sa costruire.
///
/// Sta in un file suo, senza `ActivityKit` intorno, per una ragione precisa: il
/// tipo che ActivityKit pretende esiste solo su iOS, e il Mac deve poter
/// riempire questo contenuto — è lui a sapere cosa sta succedendo. Il tipo di
/// ActivityKit lo contiene e non lo duplica.
public struct ClaudeIslandState: Codable, Hashable, Sendable {
    /// Percentuale della finestra di cinque ore, 0-100.
    public var fiveHourPercent: Double?
    /// Quando si azzera, per il conto alla rovescia che il sistema tiene da sé.
    public var fiveHourResetsAt: Date?

    public var sevenDayPercent: Double?
    public var sevenDayResetsAt: Date?

    /// I progetti, al massimo tre: quante righe ci stanno.
    public var projects: [Project]

    /// La chat da aprire toccando l'isola.
    public var alertSessionID: String?

    /// Il tipo di avviso in corso. Il valore grezzo di `ClaudeAlertKind`, così un
    /// tipo aggiunto in futuro non fa fallire la decodifica di un'attività già in
    /// corso sul telefono di qualcuno.
    public var alertKind: String?

    /// La domanda o il permesso in attesa, in una riga.
    public var pending: String?

    /// Quando il Mac ha detto queste cose.
    public var updatedAt: Date

    public init(
        fiveHourPercent: Double? = nil,
        fiveHourResetsAt: Date? = nil,
        sevenDayPercent: Double? = nil,
        sevenDayResetsAt: Date? = nil,
        projects: [Project] = [],
        alertSessionID: String? = nil,
        alertKind: String? = nil,
        pending: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.fiveHourPercent = fiveHourPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayPercent = sevenDayPercent
        self.sevenDayResetsAt = sevenDayResetsAt
        self.projects = projects
        self.alertSessionID = alertSessionID
        self.alertKind = alertKind
        self.pending = pending
        self.updatedAt = updatedAt
    }

    /// Il tipo di avviso, se è uno che questa versione conosce.
    public var alert: ClaudeAlertKind? {
        alertKind.flatMap(ClaudeAlertKind.init(rawValue:))
    }

    /// Se dice le stesse cose di un altro, **a parte l'ora**.
    ///
    /// ## Perché non basta `==`
    ///
    /// `updatedAt` cambia a ogni fotografia, anche quando tutto il resto è
    /// identico: da sola farebbe sembrare cambiato tutto, sempre. E questa
    /// domanda viene posta esattamente per decidere se valga la pena spendere
    /// qualcosa — una notifica dal Mac, una ricarica dei widget sul telefono — su
    /// un contenuto che potrebbe essere lo stesso di prima.
    ///
    /// ## Perché sta qui e non nei due posti che la pongono
    ///
    /// La pongono in due: `RemotePublisher.islandToSend()` sul Mac, per non
    /// rispedire un'isola identica, e `SharedStore.contentDiffers(from:)` sul
    /// telefono, per non bruciare il bilancio delle ricariche. Erano la stessa
    /// riga scritta due volte, e due copie di una regola di uguaglianza
    /// divergono in modo particolarmente sgradevole: il Mac deciderebbe che una
    /// cosa è cambiata e il telefono che non lo è, o viceversa, e nessuno dei due
    /// avrebbe torto sul proprio codice.
    public func describesSameContent(as other: ClaudeIslandState) -> Bool {
        var a = self, b = other
        let epoch = Date(timeIntervalSince1970: 0)
        a.updatedAt = epoch
        b.updatedAt = epoch
        return a == b
    }

    /// Cosa è successo, in una riga.
    public var headline: String {
        guard let alert else { return "Vibing Code Live" }
        switch alert {
        case .waiting: return "Claude aspetta una risposta"
        case .done: return "Claude ha finito"
        case .failed: return "Claude si è interrotto"
        }
    }

    /// Se descrive la stessa **situazione** di un altro: gli stessi progetti
    /// negli stessi stati, la stessa richiesta in attesa, lo stesso avviso.
    ///
    /// ## Perché non basta `describesSameContent(as:)`
    ///
    /// Quello confronta tutto tranne l'ora, percentuali comprese — ed è giusto
    /// per decidere se *ridisegnare*. Ma le percentuali salgono di continuo:
    /// usarle per decidere se **svegliare il telefono** vuol dire spendere un
    /// risveglio ogni volta che l'utilizzo passa da 14 a 15, cioè consumare in
    /// rumore un bilancio che iOS concede con parsimonia. E quando poi cambia
    /// davvero uno stato, il sistema ci ha già visti chiedere troppo.
    ///
    /// Quindi qui percentuali e date di azzeramento **non** contano: contano i
    /// progetti, i loro stati, e ciò che sta aspettando una risposta. Cioè le
    /// cose per cui vale la pena guardare il telefono adesso invece che fra
    /// dieci minuti.
    public func describesSameSituation(as other: ClaudeIslandState) -> Bool {
        projects == other.projects
            && pending == other.pending
            && alertKind == other.alertKind
            && alertSessionID == other.alertSessionID
    }

    /// Un progetto nell'elenco dell'isola.
    public struct Project: Codable, Hashable, Identifiable, Sendable {
        public var name: String

        /// Il percorso completo, per il collegamento che apre *questo* progetto.
        ///
        /// Non esce dal telefono: finisce dentro un indirizzo `claudelive://` che
        /// iOS passa all'app. Il nome da solo non basterebbe — due progetti
        /// possono chiamarsi uguale in cartelle diverse.
        public var path: String

        /// Lo stato, col nome che ha nel pacchetto: `ClaudeActivity`. Nome
        /// scomodo nel contesto dell'isola — «attività» è anche quella — ma
        /// rinominarlo toccherebbe il Mac per una comodità di lettura.
        public var state: ClaudeActivity

        /// Se è quello di cui parla l'avviso in corso.
        public var alerting: Bool

        public var id: String { name }

        public init(name: String, path: String, state: ClaudeActivity, alerting: Bool) {
            self.name = name
            self.path = path
            self.state = state
            self.alerting = alerting
        }
    }

    // MARK: - Dalla fotografia

    /// Cosa dell'intera fotografia finisce nell'isola.
    ///
    /// Nel pacchetto e non nell'app perché la costruiscono in due: l'app quando
    /// gira, e il **Mac** quando deve sigillarla e mandarla dentro una notifica.
    /// Due copie di questa scelta divergerebbero, e la divergenza si vedrebbe
    /// come un'isola che cambia contenuto a seconda di chi l'ha aggiornata.
    ///
    /// Poco, e scelto: nello spazio dell'isola una cosa in più è una cosa in meno
    /// leggibile. I due contatori perché sono il motivo per cui si guarda là, e
    /// cinque progetti perché è quanto la schermata di blocco riesce a mostrare —
    /// l'isola aperta ne prenderà due, che è quanto le sta.
    public init(snapshot: RemoteSnapshot) {
        let alertPath = snapshot.alert?.projectPath

        let projects = snapshot.projects.prefix(5).map { project in
            Project(
                name: (project.projectPath as NSString).lastPathComponent,
                path: project.projectPath,
                state: project.state,
                alerting: project.projectPath == alertPath
            )
        }

        let waiting = snapshot.sessions.first { $0.isDecidable }
        let pending: String? = {
            guard let waiting else { return nil }
            if let asked = snapshot.questions?[waiting.sessionID]?.first {
                return asked.question
            }
            return waiting.toolSummary
        }()

        self.init(
            fiveHourPercent: snapshot.usage?.fiveHour?.percent,
            fiveHourResetsAt: snapshot.usage?.fiveHour?.resetAt,
            sevenDayPercent: snapshot.usage?.sevenDay?.percent,
            sevenDayResetsAt: snapshot.usage?.sevenDay?.resetAt,
            projects: Array(projects),
            // La chat da aprire: quella della richiesta in attesa se c'è,
            // altrimenti quella nominata dall'avviso. Toccando l'isola si finisce
            // dove c'è qualcosa da fare, non nella schermata iniziale.
            alertSessionID: waiting?.sessionID ?? snapshot.alert?.sessionID,
            alertKind: snapshot.alert?.kind.rawValue,
            pending: pending,
            updatedAt: snapshot.generatedAt
        )
    }
}
