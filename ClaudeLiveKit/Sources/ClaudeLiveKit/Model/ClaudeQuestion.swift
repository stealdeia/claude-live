import Foundation

/// Una domanda a scelta multipla posta da Claude Code.
///
/// Esiste perché in modalità automatica una domanda è **l'unica cosa** che si
/// ferma ad aspettare una persona: i permessi si risolvono da sé, e il pannello
/// — nato per i permessi — restava muto proprio quando c'era qualcosa da fare.
///
/// Sta nel pacchetto condiviso e non nell'app per Mac perché la stessa domanda
/// andrà mostrata sul telefono, e un modello riscritto due volte è un modello
/// che divergerà.
public struct ClaudeQuestion: Codable, Equatable, Identifiable, Sendable {
    /// Una delle risposte proposte.
    public struct Option: Codable, Equatable, Identifiable, Sendable {
        /// Ciò che si sceglie, e ciò che va rimandato indietro **alla lettera**:
        /// Claude Code riconosce la risposta confrontandola con le etichette, e
        /// una parola cambiata la fa passare per una risposta libera.
        public let label: String

        /// A cosa porta quella scelta. Vale la pena mostrarla: è la differenza
        /// fra scegliere e indovinare.
        public let description: String

        public var id: String { label }

        public init(label: String, description: String) {
            self.label = label
            self.description = description
        }
    }

    public let question: String

    /// L'etichetta breve con cui Claude riassume la domanda. Comoda quando lo
    /// spazio non basta al testo intero.
    public let header: String

    /// Se si possono scegliere più opzioni insieme.
    public let multi: Bool

    public let options: [Option]

    /// Il testo della domanda: è anche la chiave con cui la risposta va
    /// rispedita, quindi due domande identiche nella stessa chiamata sarebbero
    /// comunque indistinguibili per Claude Code.
    public var id: String { question }

    public init(question: String, header: String, multi: Bool, options: [Option]) {
        self.question = question
        self.header = header
        self.multi = multi
        self.options = options
    }

    /// Come una scelta va scritta per Claude Code.
    ///
    /// Le scelte multiple si uniscono con «, » perché lo schema dello strumento
    /// vuole una stringa e Claude Code separa proprio su quella sequenza per
    /// riconoscere le etichette. Un separatore diverso farebbe passare tutto per
    /// una risposta scritta a mano.
    public static func joined(_ labels: [String]) -> String {
        labels.joined(separator: ", ")
    }
}
