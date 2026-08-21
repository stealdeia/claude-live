import Foundation

/// I titoli che Claude Code dà alle chat, letti dalle sue trascrizioni.
///
/// Il pannello mostrava «chat 0eaac6»: i primi sei caratteri dell'identificativo
/// della sessione, che è l'unica cosa con cui l'hook sa distinguere due chat.
/// Nessuno riconosce una conversazione da quello.
///
/// Claude Code però un titolo lo ha, e lo scrive: dentro la trascrizione della
/// sessione, in record `ai-title`, ed è esattamente la stringa che si legge sopra
/// la conversazione.
///
/// Letto dalla **coda** del file e non dall'inizio: una trascrizione arriva a
/// decine di megabyte, i titoli vengono riscritti man mano che la conversazione
/// procede — in una sessione di oggi ce n'erano 136 — e l'unico che conta è
/// l'ultimo. Gli ultimi 128 KB lo contengono sempre e costano niente.
enum ChatTitles {
    private static let tailBytes: UInt64 = 128 * 1024

    /// Quanto tenere un titolo prima di riguardare.
    ///
    /// Non basta la data di modifica del file: durante una conversazione attiva
    /// quella cambia ogni pochi secondi, e rileggere 128 KB a ogni scansione
    /// sarebbe lavoro buttato — il titolo cambia una volta ogni tante risposte.
    private static let freshness: TimeInterval = 15

    private struct Cached {
        let title: String?
        let readAt: Date
    }

    private static let lock = NSLock()
    private static var titles: [String: Cached] = [:]
    private static var transcripts: [String: URL] = [:]

    /// Il titolo di una chat, o `nil` se non ne ha ancora uno.
    static func title(projectPath: String, sessionID: String) -> String? {
        lock.lock()
        if let hit = titles[sessionID], Date().timeIntervalSince(hit.readAt) < freshness {
            lock.unlock()
            return hit.title
        }
        lock.unlock()

        let found = transcript(projectPath: projectPath, sessionID: sessionID).flatMap(lastTitle)
        lock.lock()
        titles[sessionID] = Cached(title: found, readAt: Date())
        lock.unlock()
        return found
    }

    // MARK: - Dove sta la trascrizione

    /// Claude Code sostituisce con `-` tutto ciò che non è una lettera o una
    /// cifra: `/Users/tizio/Repository Github/x` diventa
    /// `-Users-tizio-Repository-Github-x`.
    private static func encoded(_ path: String) -> String {
        String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    private static func transcript(projectPath: String, sessionID: String) -> URL? {
        lock.lock()
        if let known = transcripts[sessionID] {
            lock.unlock()
            return FileManager.default.fileExists(atPath: known.path) ? known : nil
        }
        lock.unlock()

        let root = Paths.home.appendingPathComponent(".claude/projects")
        let direct = root
            .appendingPathComponent(encoded(projectPath))
            .appendingPathComponent("\(sessionID).jsonl")

        var found: URL?
        if FileManager.default.fileExists(atPath: direct.path) {
            found = direct
        } else {
            // La regola di codifica è dedotta, non documentata: se non torna, la
            // sessione si cerca. Gli identificativi sono unici, quindi il primo
            // che porta quel nome è quello giusto — e il risultato resta in cache,
            // così la ricerca avviene una volta per chat.
            let dirs = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            )) ?? []
            for dir in dirs {
                let candidate = dir.appendingPathComponent("\(sessionID).jsonl")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    found = candidate
                    break
                }
            }
        }

        guard let found else { return nil }
        lock.lock()
        transcripts[sessionID] = found
        lock.unlock()
        return found
    }

    // MARK: - Leggere la coda

    private static func lastTitle(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > tailBytes ? end - tailBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // A ritroso: il titolo valido è l'ultimo scritto. La prima riga del pezzo
        // letto è quasi certamente troncata a metà, e per questo non viene
        // trattata come un caso speciale — non si decodifica e si passa oltre.
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard line.count < 64 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "ai-title",
                  let title = (object["aiTitle"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty
            else { continue }
            return title
        }
        return nil
    }
}
