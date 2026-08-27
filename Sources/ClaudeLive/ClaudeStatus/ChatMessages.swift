import Foundation
import ClaudeLiveKit

/// Gli ultimi messaggi di una conversazione, per poterla leggere dal telefono.
///
/// ## Cosa tiene e cosa butta
///
/// In una trascrizione vera i messaggi leggibili sono la minoranza delle righe:
/// misurato su una sessione di questo progetto, 676 chiamate agli strumenti, 675
/// risultati e 537 ragionamenti interni contro 572 messaggi di testo. Quello che
/// arriva sul telefono è solo l'ultima categoria, perché è l'unica che si
/// leggerebbe guardando la chat.
///
/// I ragionamenti interni restano fuori di proposito e non per dimensione: non
/// sono ciò che Claude ha *detto*, e leggerli come se lo fossero darebbe un
/// resoconto della conversazione che la conversazione non contiene.
///
/// ## Come
///
/// Si legge la coda del file e si torna indietro fino a raccogliere quanti
/// messaggi servono, così una chat lunga costa quanto una corta. La prima riga
/// del pezzo letto è quasi certamente troncata a metà: non è un caso speciale,
/// semplicemente non si decodifica e si passa oltre.
enum ChatMessages {
    /// Quanto leggere dalla fine.
    ///
    /// Due megabyte, misurati e non scelti a occhio: con 512 KB questa sessione
    /// dava 16 messaggi invece di 20, perché fra un messaggio e l'altro ci sono i
    /// risultati degli strumenti, che occupano molto spazio e vengono buttati. Un
    /// megabyte bastava, due danno margine — e questa è una delle sessioni più
    /// cariche di lavoro che ci siano (14,7 MB di trascrizione), quindi è il caso
    /// peggiore, non quello medio.
    ///
    /// Il costo di leggerne tanti è basso: la cache qui sotto tiene il risultato
    /// per cinque secondi, e il pannello ridisegna molto più spesso.
    private static let tailBytes: UInt64 = 2 * 1024 * 1024

    /// Quanto testo al massimo per una chat.
    ///
    /// Non un limite per messaggio: i messaggi arrivano **interi**. Tagliarli a
    /// novecento caratteri era una precauzione presa a occhio, e la misura del
    /// 2026-08-27 l'ha smentita — venti messaggi interi di una sessione vera
    /// sono 7.300 caratteri in tutto, mediana 105, e il taglio colpiva solo i
    /// tre che valeva la pena leggere.
    ///
    /// Resta un tetto sul totale perché una chat fatta di venti messaggi
    /// lunghissimi è possibile, e la fotografia viene spedita a ogni
    /// cambiamento. Si raccoglie dal più recente, quindi ciò che eventualmente
    /// resta fuori è il contesto più vecchio.
    private static let maxCharactersPerChat = 60_000

    private struct Cached {
        let messages: [ClaudeMessage]
        let at: Date
    }

    /// Rilette non più spesso di così: il pannello ridisegna a raffica e il file
    /// è grande.
    private static let freshness: TimeInterval = 5

    private static let lock = NSLock()
    private static var cache: [String: Cached] = [:]

    static func recent(projectPath: String, sessionID: String, limit: Int) -> [ClaudeMessage] {
        let key = "\(sessionID)#\(limit)"
        lock.lock()
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < freshness {
            lock.unlock()
            return hit.messages
        }
        lock.unlock()

        let found = ChatTitles.transcript(projectPath: projectPath, sessionID: sessionID)
            .map { read(url: $0, limit: limit) } ?? []

        lock.lock()
        cache[key] = Cached(messages: found, at: Date())
        lock.unlock()
        return found
    }

    // MARK: - Lettura

    private static func read(url: URL, limit: Int) -> [ClaudeMessage] {
        guard limit > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return [] }
        let start = end > tailBytes ? end - tailBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        var collected: [ClaudeMessage] = []
        var used = 0
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard collected.count < limit, used < maxCharactersPerChat else { break }
            guard line.count < 2 * 1024 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  // Zero: nessun taglio. Il messaggio arriva come è stato scritto.
                  let message = ClaudeMessage.from(record: object, maxCharacters: 0)
            else { continue }
            collected.append(message)
            used += message.text.count
        }
        // Raccolti a ritroso, letti in avanti.
        return collected.reversed()
    }

}
