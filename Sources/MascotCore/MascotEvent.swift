import Foundation

/// Quello che l'app racconta alla mascotte.
///
/// Un elenco corto e generico di proposito: la mascotte non deve sapere cos'è
/// un hook di Claude Code, né cosa sia una sessione, né tantomeno un progetto.
/// Sa che «è successo qualcosa di cui vale la pena accorgersi» e che «c'è del
/// lavoro in corso». Chi traduce i fatti dell'app in queste tre righe è un
/// adattatore che sta da un'altra parte — così aggiungere un nuovo motivo per
/// far saltare il pupazzetto non tocca né la macchina a stati né i disegni.
public enum MascotEvent: Equatable, Sendable {
    /// È successo qualcosa: il personaggio se ne accorge e lo fa notare.
    case notice(MascotNotice)

    /// C'è del lavoro in corso, oppure non ce n'è più.
    case working(Bool)

    /// Un segno di vita qualsiasi dell'utente. Non cambia quello che il
    /// personaggio sta facendo: serve solo a non farlo addormentare.
    case poked

}

/// Una notizia, con quel tanto che basta per raccontarla.
///
/// Il progetto e il dettaglio viaggiano insieme al tipo perché il fumetto sopra
/// la testa deve **dire cos'è successo**, e non c'è modo di ricostruirlo dopo:
/// quando il personaggio smette di saltare, l'avviso che l'aveva fatto saltare
/// può già essere stato spento da qualcun altro.
public struct MascotNotice: Equatable, Sendable {
    /// Il *tipo* di notizia.
    ///
    /// Oggi tutte e tre fanno la stessa animazione. Viaggiano distinte lo stesso
    /// perché è l'informazione che serve il giorno in cui una mascotte vorrà
    /// festeggiare diversamente da come si spaventa.
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        /// Il turno è finito.
        case finished
        /// Claude aspetta una risposta.
        case needsYou
        /// Qualcosa si è interrotto.
        case failed
    }

    public let kind: Kind
    /// Il progetto di cui si parla.
    public let project: String
    /// Cosa è successo, in poche parole: lo strumento, l'errore, la domanda.
    public let detail: String?

    public init(kind: Kind, project: String, detail: String? = nil) {
        self.kind = kind
        self.project = project
        self.detail = detail
    }

    /// La prima riga del fumetto.
    public var headline: String {
        switch kind {
        case .finished: return "Ho finito in \(project)"
        case .needsYou: return "\(project) ti aspetta"
        case .failed: return "Mi sono interrotto in \(project)"
        }
    }
}
