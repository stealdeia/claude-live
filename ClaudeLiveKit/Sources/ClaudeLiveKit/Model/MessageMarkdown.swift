import Foundation

/// Il testo di un messaggio reso leggibile in una bolla di chat.
///
/// Claude scrive in Markdown, e mostrarlo così com'è vuol dire mostrare gli
/// asterischi: `**davvero**` invece di **davvero**. Ma un lettore di Markdown
/// completo qui sarebbe di troppo — in una bolla larga trecento punti non ci
/// stanno titoli di primo livello, tabelle e blocchi di codice numerati.
///
/// Quindi: il grassetto, il corsivo e il codice in linea vengono resi davvero;
/// le poche costruzioni *a blocchi* che Claude usa spesso vengono tradotte in
/// qualcosa che una bolla sa mostrare; il resto passa come testo. Ogni scelta ha
/// come alternativa «lasciare i simboli a vista», che è il difetto da cui questo
/// file nasce.
public enum MessageMarkdown {
    /// Il testo pronto da mettere in una `Text`.
    public static func attributed(_ text: String) -> AttributedString {
        let source = prepared(text)
        // `inlineOnlyPreservingWhitespace` e non il lettore completo: quello
        // butterebbe via gli a capo, e un messaggio di Claude senza a capo è un
        // muro. Le costruzioni a blocchi le ha già tradotte `prepared`.
        if let parsed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            return parsed
        }
        // Un Markdown malformato non deve far sparire il messaggio: meglio i
        // simboli a vista che una bolla vuota.
        return AttributedString(source)
    }

    /// Traduce le costruzioni a blocchi in qualcosa che una bolla sa mostrare.
    ///
    /// Interna e non privata perché è la parte che può sbagliare, e le prove la
    /// guardano riga per riga.
    static func prepared(_ text: String) -> String {
        var result: [String] = []
        var insideFence = false

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // I recinti del codice (```swift … ```) spariscono, il codice dentro
            // resta: la riga di recinto non è contenuto, e mostrarla sarebbe come
            // stampare il bordo di una tabella.
            if trimmed.hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if insideFence {
                result.append(line)
                continue
            }

            if let heading = headingAsBold(trimmed) {
                result.append(heading)
                continue
            }

            if let bullet = bulletAsDot(line, trimmed: trimmed) {
                result.append(bullet)
                continue
            }

            // Una riga di soli tratti separa due paragrafi in Markdown; in una
            // bolla è una fila di trattini che sembra un errore.
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                result.append("")
                continue
            }

            result.append(line)
        }

        return result.joined(separator: "\n")
    }

    /// `## Titolo` diventa `**Titolo**`: in una bolla un titolo è una riga in
    /// grassetto, non un corpo tipografico diverso.
    private static func headingAsBold(_ trimmed: String) -> String? {
        var hashes = 0
        for character in trimmed {
            if character == "#" { hashes += 1 } else { break }
        }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        // Se il titolo è già in grassetto non si raddoppia, o gli asterischi
        // tornerebbero a vista.
        if rest.hasPrefix("**") && rest.hasSuffix("**") { return rest }
        return "**\(rest)**"
    }

    /// `- voce` diventa `• voce`, conservando il rientro di una lista annidata.
    ///
    /// Solo con lo spazio dopo il segno: `*corsivo*` comincia con un asterisco e
    /// non è un elenco, e trattarlo come tale ne mangerebbe il primo carattere.
    private static func bulletAsDot(_ line: String, trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            return indent + "• " + String(trimmed.dropFirst(marker.count))
        }
        return nil
    }
}
