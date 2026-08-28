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

    /// La chiave con cui aprire le scatole sigillate, consegnata all'estensione
    /// insieme all'attività.
    ///
    /// ## Perché non basta il portachiavi
    ///
    /// Era là, in un gruppo condiviso fra app ed estensione, ed è il modo giusto
    /// di condividere un segreto. Solo che dall'estensione non si raggiunge: il
    /// portachiavi risponde **-25291**, «nessun portachiavi disponibile» —
    /// misurato sul telefono, non dedotto. Non «non hai il diritto» e non «la
    /// voce non c'è»: proprio irraggiungibile da quel processo. Per questo
    /// l'isola mostrava trattini e riaprire l'app li faceva tornare: l'app usa
    /// l'altra strada, quella in chiaro, che non ha bisogno di aprire niente.
    ///
    /// ## Cosa cambia, onestamente
    ///
    /// La chiave passa dal portachiavi al deposito che iOS tiene per le Live
    /// Activity. È un posto meno protetto — questo va detto — ma resta **sul
    /// telefono**: non viaggia in rete, non finisce al relay, e la proprietà che
    /// conta non si tocca. Chi trasporta le notifiche continua a non poter
    /// leggere né i nomi dei progetti né cosa Claude sta chiedendo.
    ///
    /// Facoltativa: se un giorno il portachiavi tornasse raggiungibile,
    /// l'estensione prova prima quello.
    public var key: String?

    public init(startedAt: Date = Date(), key: String? = nil) {
        self.startedAt = startedAt
        self.key = key
    }
}
#endif
