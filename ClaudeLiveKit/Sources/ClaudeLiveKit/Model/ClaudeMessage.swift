import Foundation

/// Un messaggio di una conversazione, come si legge sul telefono.
///
/// Volutamente povero: chi, cosa, quando. Non è una trascrizione fedele e non
/// vuole esserlo — nella trascrizione vera ci sono i ragionamenti interni, le
/// chiamate agli strumenti e i loro risultati, che sono la maggior parte delle
/// righe e non sono la conversazione. Quello che resta è ciò che si leggerebbe
/// guardando la chat.
public struct ClaudeMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Author: String, Codable, Sendable {
        case user
        case assistant
    }

    public let author: Author
    public let text: String

    /// Quando è stato scritto, se la trascrizione lo dice. Le prime righe di una
    /// sessione a volte non hanno l'ora, e mancarla è meglio che inventarla.
    public let at: Date?

    public init(author: Author, text: String, at: Date?) {
        self.author = author
        self.text = text
        self.at = at
    }

    /// Un'identità che non cambia quando la finestra dei venti messaggi scorre.
    ///
    /// Serve perché la chat li elencava per **posizione**. Quando arriva un
    /// messaggio nuovo la finestra scorre — il più vecchio esce, l'ultimo entra —
    /// e tutte le posizioni si spostano di uno: chi disegna vede venti righe
    /// diverse invece di una aggiunta, butta via tutti i fumetti e li rifà,
    /// rimisurando venti blocchi di testo formattato. Il risultato era la chat
    /// che rimbalza, il telefono che scalda e l'app che va a scatti.
    ///
    /// Chi, quando e quanto è lungo: due messaggi diversi dovrebbero avere lo
    /// stesso autore, lo stesso millesimo di secondo e la stessa lunghezza per
    /// confondersi. La lunghezza al posto del testo perché questa identità viene
    /// ricalcolata a ogni disegno, e confrontare venti stringhe intere per
    /// riconoscere venti righe è il lavoro che stiamo cercando di evitare.
    public var id: String {
        "\(author.rawValue)#\(at?.timeIntervalSince1970 ?? 0)#\(text.count)"
    }

    // MARK: - Dalla trascrizione

    /// Le etichette che Claude Code infila nei messaggi dell'utente senza che
    /// l'utente le abbia scritte: promemoria di sistema, selezioni dell'editor,
    /// output di comandi locali. Tolte perché non sono cose dette da qualcuno, e
    /// sul telefono sembrerebbero parte del discorso.
    private static let noiseTags = [
        "system-reminder", "ide_selection", "command-name", "command-message",
        "command-args", "local-command-stdout", "local-command-stderr",
        // Aggiunta il 2026-08-27: nella chat sul telefono comparivano fumetti
        // attribuiti a Stefano che contenevano l'avviso di fine di un lavoro in
        // sottofondo. «Viene fuori questa ma io non ho mai scritto nulla.»
        "task-notification",
    ]

    /// Un messaggio leggibile da una riga di trascrizione, o `nil` se quella riga
    /// non contiene niente da leggere.
    ///
    /// Sta qui e non nell'app perché è la parte che può sbagliare: la forma dei
    /// record non è documentata, è stata misurata, e va sorvegliata da una prova.
    /// Il resto — aprire il file e leggerne la coda — non ha niente da provare.
    ///
    /// Scartano: i ragionamenti interni (`thinking`), le chiamate agli strumenti
    /// e i loro risultati, le immagini. Su una sessione reale di questo progetto
    /// erano 1.888 righe contro 572 di conversazione: tenerle vorrebbe dire
    /// mandare al telefono il lavoro invece del discorso.
    public static func from(record: [String: Any], maxCharacters: Int = 900) -> ClaudeMessage? {
        guard let kind = record["type"] as? String,
              let author = Author(rawValue: kind),
              let envelope = record["message"] as? [String: Any]
        else { return nil }

        let raw = readable(envelope["content"])

        // Il seguito scritto dal telefono, che è l'unica eccezione alla regola
        // qui sotto: arriva contrassegnato come inserito dal sistema — Claude
        // Code non distingue fra un hook che gli passa un'istruzione e uno che
        // gli passa le parole di una persona — ma è la sola cosa così
        // contrassegnata che qualcuno ha davvero scritto. Nasconderla sarebbe il
        // difetto del riassunto al contrario: là mostravamo come suo ciò che non
        // aveva scritto, qui nasconderemmo ciò che ha scritto.
        if let written = promptFromPhone(raw) {
            return ClaudeMessage(
                author: .user,
                text: shortened(written, to: maxCharacters),
                at: parsedDate(record["timestamp"] as? String)
            )
        }

        guard !isInjected(record) else { return nil }

        let cleaned = withoutNoise(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !isOneElement(cleaned) else { return nil }

        return ClaudeMessage(
            author: author,
            text: shortened(cleaned, to: maxCharacters),
            at: parsedDate(record["timestamp"] as? String)
        )
    }

    /// Il prefisso con cui Claude Code registra ciò che un hook `Stop` gli
    /// consegna per far proseguire il turno.
    ///
    /// Verificato dentro il programma di Claude Code e non dedotto: la riga è
    /// composta come «nome dell'evento» + « hook feedback:» + il testo. È il
    /// modo in cui il seguito scritto dal telefono entra nella conversazione.
    private static let promptMarker = "Stop hook feedback:"

    /// Il testo di un seguito scritto dal telefono, senza l'involucro.
    ///
    /// Nil per qualunque altra riga: il confronto è sull'inizio esatto, perché
    /// un messaggio vero che *parla* di questa cosa — e in questo progetto
    /// capita — non deve essere scambiato per uno.
    private static func promptFromPhone(_ text: String) -> String? {
        guard text.hasPrefix(promptMarker) else { return nil }
        let written = text.dropFirst(promptMarker.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return written.isEmpty ? nil : written
    }

    /// Se la riga è stata messa lì dal sistema invece che da una persona.
    ///
    /// Sono registrate come `user` — hanno il ruolo di chi parla — ma nessuno le
    /// ha scritte: il riassunto che il sistema inserisce quando la conversazione
    /// viene compattata è comparso nell'app come un messaggio lunghissimo
    /// attribuito a chi stava solo guardando, e «Continue from where you left
    /// off.» è la stessa cosa in piccolo.
    ///
    /// Tre contrassegni e non uno perché non descrivono la stessa cosa e non è
    /// detto che viaggino insieme: `isCompactSummary` è il riassunto,
    /// `isMeta` la riga di servizio, `isVisibleInTranscriptOnly` quello che si
    /// vede nella trascrizione ma non è stato detto a nessuno. Ne basta uno.
    private static func isInjected(_ record: [String: Any]) -> Bool {
        for flag in ["isCompactSummary", "isMeta", "isVisibleInTranscriptOnly"]
        where record[flag] as? Bool == true {
            return true
        }
        return false
    }

    /// Il testo di un messaggio, qualunque forma abbia `content`.
    ///
    /// Può essere una stringa oppure un elenco di blocchi, di cui interessano
    /// solo quelli di testo.
    private static func readable(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n\n")
    }

    /// Se il messaggio è tutto dentro un'unica etichetta.
    ///
    /// L'elenco qui sopra è una lista di nomi noti, e una lista di nomi noti è
    /// sempre in ritardo: `task-notification` ci è arrivata dopo essere comparsa
    /// in una chat, attribuita a una persona che non l'aveva scritta. Questa
    /// regola non ha bisogno di conoscere il nome — se *tutto* il messaggio è un
    /// solo elemento, non è una frase detta da qualcuno.
    ///
    /// Solo l'intero messaggio, e questo è il punto delicato: le etichette
    /// compaiono anche *dentro* messaggi veri — `<project>`, `<id>`, `<n>` sono
    /// nei messaggi di questo progetto — e togliere ogni cosa fra parentesi
    /// angolari mangerebbe pezzi di conversazione.
    private static func isOneElement(_ text: String) -> Bool {
        guard text.hasPrefix("<"), text.hasSuffix(">"),
              let nameEnd = text.firstIndex(of: ">")
        else { return false }
        let name = text[text.index(after: text.startIndex)..<nameEnd]
        guard !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return false }
        return text.hasSuffix("</\(name)>")
    }

    private static func withoutNoise(_ text: String) -> String {
        var result = text
        for tag in noiseTags {
            // Ripetuto finché ce n'è: in un messaggio solo possono essercene più
            // di uno, e una passata sola ne lascerebbe indietro.
            while let open = result.range(of: "<\(tag)>"),
                  let close = result.range(
                      of: "</\(tag)>", range: open.upperBound..<result.endIndex
                  ) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        return result
    }

    private static func shortened(_ text: String, to limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    private static func parsedDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        // Le trascrizioni scrivono i millisecondi («2026-08-20T07:11:51.845Z»),
        // che il formato predefinito rifiuta.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: raw) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
