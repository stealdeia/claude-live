import Foundation

/// Una sessione di Claude Code, ridotta a quello che serve per decidere dove va
/// un messaggio scritto nella barra.
///
/// Un tipo suo e non la sessione vera: la mascotte non deve sapere cos'è una
/// sessione di Claude Code — e questa regola, che è la parte che si può
/// sbagliare, si prova senza tirarsi dietro mezza applicazione.
public struct MascotPromptCandidate: Equatable, Sendable {
    public let sessionID: String
    public let projectName: String
    /// Claude sta macinando: quello che si scrive adesso parte a fine turno.
    public let isWorking: Bool
    /// L'hook è fermo ad aspettare un seguito: quello che si scrive parte subito.
    public let acceptsFollowUp: Bool
    /// La domanda in sospeso, se ce n'è una: allora la barra è la risposta.
    public let pendingQuestion: String?
    /// Un permesso da consentire o negare. Non è una cosa da scrivere.
    public let awaitingPermission: Bool
    public let updatedAt: Date

    public init(
        sessionID: String,
        projectName: String,
        isWorking: Bool,
        acceptsFollowUp: Bool,
        pendingQuestion: String?,
        awaitingPermission: Bool,
        updatedAt: Date
    ) {
        self.sessionID = sessionID
        self.projectName = projectName
        self.isWorking = isWorking
        self.acceptsFollowUp = acceptsFollowUp
        self.pendingQuestion = pendingQuestion
        self.awaitingPermission = awaitingPermission
        self.updatedAt = updatedAt
    }
}

/// Dove va a finire quello che si scrive nella barra — e quindi anche cosa la
/// barra deve dire prima che lo si scriva.
public enum MascotPromptTarget: Equatable, Sendable {
    /// C'è una domanda in sospeso: il testo è la risposta, e parte subito.
    case question(sessionID: String, project: String, question: String)
    /// L'hook sta trattenendo la fine del turno: il testo parte subito.
    case followUp(sessionID: String, project: String)
    /// Claude sta lavorando: il testo resta in coda e parte a turno finito.
    case queue(sessionID: String, project: String)
    /// Claude chiede un permesso: non è una cosa a cui si risponde scrivendo.
    case permission(project: String)
    /// Non c'è niente a cui parlare.
    case none

    /// Se si può scrivere e mandare.
    public var acceptsText: Bool {
        switch self {
        case .question, .followUp, .queue: return true
        case .permission, .none: return false
        }
    }

    /// Il progetto a cui si sta parlando, se c'è.
    public var project: String? {
        switch self {
        case .question(_, let project, _), .followUp(_, let project),
             .queue(_, let project), .permission(let project):
            return project
        case .none:
            return nil
        }
    }
}

public enum MascotPromptRouting {
    /// A chi parla la barra, fra tutte le sessioni aperte.
    ///
    /// L'ordine delle regole **è** la regola, e vale la pena dirlo per esteso
    /// perché ognuna scavalca la precedente per un motivo diverso:
    ///
    /// 1. **Una domanda in sospeso** vince su tutto: c'è qualcuno fermo che
    ///    aspetta una risposta, e qualunque altra cosa si scrivesse lo
    ///    lascerebbe lì ad aspettare.
    /// 2. **Un seguito trattenuto** viene dopo: anche lì l'hook è fermo, ma non
    ///    sta chiedendo niente — si può scrivere, e parte subito.
    /// 3. **Il lavoro in corso** è il caso normale stando al Mac: si scrive
    ///    adesso e parte quando Claude ha finito.
    /// 4. **Un permesso** è l'unico stato in cui c'è qualcuno in attesa e non
    ///    c'è niente da scrivere: la barra lo dice invece di far scrivere a
    ///    vuoto.
    ///
    /// A parità di categoria vince la sessione che si è mossa più di recente:
    /// con due chat aperte, quella che hai davanti è quasi sempre quella che si
    /// è appena mossa.
    public static func target(among candidates: [MascotPromptCandidate]) -> MascotPromptTarget {
        let recentFirst = candidates.sorted { $0.updatedAt > $1.updatedAt }

        if let asking = recentFirst.first(where: { $0.pendingQuestion?.isEmpty == false }) {
            return .question(
                sessionID: asking.sessionID,
                project: asking.projectName,
                question: asking.pendingQuestion ?? ""
            )
        }
        if let held = recentFirst.first(where: \.acceptsFollowUp) {
            return .followUp(sessionID: held.sessionID, project: held.projectName)
        }
        if let working = recentFirst.first(where: \.isWorking) {
            return .queue(sessionID: working.sessionID, project: working.projectName)
        }
        if let permission = recentFirst.first(where: \.awaitingPermission) {
            return .permission(project: permission.projectName)
        }
        return .none
    }

    /// Il nome del file in cui lasciare un messaggio in coda per una sessione.
    ///
    /// Le stesse regole che usa l'hook per ricostruirlo — solo lettere, numeri,
    /// trattini e sottolineature, e non più di quaranta caratteri — perché sono
    /// due programmi diversi che devono indicare lo stesso file senza potersi
    /// parlare. Se una delle due regole cambia, la coda smette di funzionare in
    /// silenzio: è il motivo per cui questa funzione ha una prova sua.
    public static func queueFileName(forSession sessionID: String) -> String {
        let safe = sessionID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return String(safe.prefix(40)) + ".json"
    }
}
