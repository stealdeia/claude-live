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
    /// Quanto leggere dalla fine. Generoso rispetto ai titoli, perché qui una
    /// riga sola può essere un messaggio lungo e in mezzo ci sono i risultati
    /// degli strumenti, che occupano molto spazio e non vengono tenuti.
    private static let tailBytes: UInt64 = 512 * 1024

    /// Oltre questa lunghezza un messaggio viene troncato.
    ///
    /// Non per fare economia di byte: sul telefono nessuno legge tremila
    /// caratteri in una bolla, e il messaggio intero resta nella chat vera.
    private static let maxCharacters = 600

    /// L'ultimo messaggio ne ha molti di più.
    ///
    /// Perché è quello che si sta leggendo: la chat sul telefono si apre per
    /// sapere cosa Claude ha detto *adesso*, e spesso per decidere come
    /// rispondere a una domanda. Tagliarlo alla stessa misura dei messaggi di
    /// contesto vorrebbe dire troncare l'unico che conta. Gli altri sono là per
    /// inquadrarlo, e per quello bastano poche righe.
    private static let maxCharactersLatest = 3000

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
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard collected.count < limit else { break }
            guard line.count < 2 * 1024 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            // Si raccoglie a ritroso, quindi il primo che si trova è il più
            // recente: è quello che va per esteso.
            let generous = collected.isEmpty
            guard let message = ClaudeMessage.from(
                record: object,
                maxCharacters: generous ? maxCharactersLatest : maxCharacters
            ) else { continue }
            collected.append(message)
        }
        // Raccolti a ritroso, letti in avanti.
        return collected.reversed()
    }

}
