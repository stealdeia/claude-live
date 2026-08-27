#if os(iOS)
import ActivityKit
import Foundation

/// Cosa mostra la Live Activity: l'isola dinamica e la schermata di blocco.
///
/// Sta nel pacchetto condiviso perché deve essere lo stesso tipo per due
/// bersagli — l'app che avvia l'attività e l'estensione che la disegna — e due
/// definizioni che devono combaciare byte per byte non possono essere due
/// definizioni.
///
/// Su macOS non esiste, e la guardia è `os(iOS)` e **non** `canImport`: il
/// modulo ActivityKit su macOS si importa benissimo, è `ActivityAttributes`
/// dentro a essere dichiarato non disponibile. Con `canImport` il Mac non
/// compilava più.
public struct ClaudeActivityAttributes: ActivityAttributes {
    /// Ciò che cambia mentre l'attività vive: **o** il contenuto in chiaro, **o**
    /// una scatola sigillata che lo contiene.
    ///
    /// ## Perché due strade
    ///
    /// Quando l'app sta girando riempie `island` direttamente: sta parlando a se
    /// stessa, non c'è niente da nascondere a nessuno.
    ///
    /// Quando l'app non gira, l'aggiornamento arriva come notifica — e la
    /// notifica la compone il relay, che **non può leggere** quello che il Mac gli
    /// manda. Quindi il Mac gli passa una scatola sigillata, il relay la
    /// trasporta senza aprirla, e l'estensione la apre qui sul telefono con la
    /// chiave dell'accoppiamento. Da fuori non si vede né quali progetti hai né
    /// cosa Claude ti sta chiedendo.
    ///
    /// L'alternativa era mandare quelle poche cose in chiaro: metà del lavoro. I
    /// due numeri dell'utilizzo non direbbero niente di nessuno — ma i nomi dei
    /// progetti sì, e vederli è tutto il punto dell'isola.
    public struct ContentState: Codable, Hashable {
        /// Il contenuto, quando è l'app a metterlo.
        public var island: ClaudeIslandState?

        /// Il contenuto sigillato, quando arriva da una notifica.
        public var sealed: String?

        public init(island: ClaudeIslandState? = nil, sealed: String? = nil) {
            self.island = island
            self.sealed = sealed
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
