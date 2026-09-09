#if os(iOS)
import Foundation

/// La scatola che l'app e l'estensione si passano.
///
/// ## Perché un App Group e non il portachiavi
///
/// Il portachiavi era la strada giusta e non funziona: dall'estensione risponde
/// `-25291`, «nessun portachiavi disponibile» — misurato sul telefono, non
/// dedotto, ed è la ragione per cui la chiave dell'isola viaggia dentro
/// `ClaudeActivityAttributes` invece di stare dove dovrebbe. Un widget non ha un
/// equivalente di quella scappatoia: nessuno gli consegna niente all'avvio, deve
/// **andare a prendere** il suo contenuto. Quindi serve un posto che
/// l'estensione possa davvero leggere, e quel posto è il contenitore condiviso
/// del gruppo.
///
/// ## Cosa cambia sulla protezione, onestamente
///
/// Un file nel contenitore del gruppo è meno protetto di una voce del
/// portachiavi. Resta comunque **sul telefono**, dentro la sandbox di questa
/// app, cifrato dal sistema e non prima del primo sblocco dopo un riavvio; non
/// viaggia in rete, non finisce al relay, non va in iCloud. E soprattutto:
/// qui dentro non c'è nessuna chiave. Ci sono due percentuali e dei nomi di
/// progetto già in chiaro — cioè quello che il widget deve disegnare, e niente
/// che permetta di aprire qualcos'altro.
///
/// Il widget quindi non fa **né rete né crittografia**: legge un file. Dentro un
/// processo a cui il sistema concede poco tempo e poca memoria, la differenza fra
/// «leggo un file» e «apro una connessione e decifro» è la differenza fra un
/// widget che si disegna e uno che a volte no.
public enum SharedStore {

    /// Dichiarato in `iOS/project.yml` per entrambi i bersagli.
    public static let groupID = "group.it.aldeialab.ClaudeLiveMobile"

    private static let islandFile = "island.json"
    private static let themeKey = "themeID"
    private static let relayURLKey = "relayURL"
    private static let pairIDKey = "pairID"

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    private static var islandURL: URL? {
        container?.appendingPathComponent(islandFile, isDirectory: false)
    }

    // MARK: - Il contenuto

    /// Deposita il contenuto per chi lo disegnerà.
    ///
    /// Scritto **sempre**, anche identico all'ultimo: l'ora dentro `updatedAt` è
    /// parte di ciò che il widget mostra, e un deposito che non si aggiorna
    /// farebbe invecchiare la scritta «aggiornato N minuti fa» mentre il Mac sta
    /// benissimo e ripete le stesse cose. Costa la scrittura di un file di poche
    /// centinaia di byte. Chi deve decidere se *ricaricare* i widget — che invece
    /// ha un budget — lo chiede prima a `contentDiffers(from:)`.
    ///
    /// Restituisce `false` quando non ci riesce, e chi chiama lo dice: una
    /// scrittura persa in silenzio si vede solo come un widget che non si muove
    /// più, cioè come il guasto più difficile da attribuire che questo sistema
    /// abbia già avuto una volta.
    @discardableResult
    public static func write(_ island: ClaudeIslandState) -> Bool {
        guard let url = islandURL,
              let data = try? JSONEncoder().encode(island)
        else { return false }

        do {
            try data.write(to: url, options: [.atomic])
            // Dopo la scrittura e non dentro: `.atomic` scrive un file
            // temporaneo e lo rinomina, quindi un attributo chiesto prima
            // finirebbe sul file sbagliato.
            //
            // «Dopo il primo sblocco» e non «da sbloccato»: gli slot StandBy e la
            // schermata di blocco vengono disegnati proprio a telefono bloccato.
            // È lo stesso livello che `IslandKey` si è dovuto scegliere il
            // 2026-08-27, dopo un giro speso a capire perché l'isola mostrava
            // trattini sulla schermata di blocco.
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }

    /// Il contenuto da disegnare, o `nil` se non c'è.
    public static func read() -> ClaudeIslandState? {
        guard let url = islandURL,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(ClaudeIslandState.self, from: data)
    }

    /// Se il contenuto in deposito dice qualcosa di diverso da questo, a parte
    /// l'ora.
    ///
    /// La regola è `ClaudeIslandState.describesSameContent(as:)`, la stessa che il
    /// Mac usa per decidere se rispedire un'isola: se le due sponde rispondessero
    /// in modo diverso alla stessa domanda, il Mac manderebbe un aggiornamento che
    /// il telefono butta, o viceversa.
    ///
    /// Serve perché le ricariche dei widget hanno un budget, e questo metodo
    /// viene interrogato ogni cinque secondi mentre l'app è aperta: chiederne una
    /// per ridisegnare gli stessi numeri lo consumerebbe per niente.
    public static func contentDiffers(from island: ClaudeIslandState) -> Bool {
        guard let stored = read() else { return true }
        return !stored.describesSameContent(as: island)
    }

    // MARK: - Il tema

    /// Il tema scelto nell'app, dove l'estensione possa vederlo.
    ///
    /// Stava — e resta, per l'app — in `UserDefaults.standard`, che è un dominio
    /// per bersaglio: l'estensione ne ha uno suo e vuoto. È il motivo per cui
    /// l'isola ha `.midnight` scritto a mano e ignora la scelta dell'utente.
    /// Qui la scelta arriva anche a lei.
    public static var themeID: String? {
        get { UserDefaults(suiteName: groupID)?.string(forKey: themeKey) }
        set { UserDefaults(suiteName: groupID)?.set(newValue, forKey: themeKey) }
    }

    /// Il tema, già risolto, con `.midnight` quando non si sa.
    public static var theme: ColorTheme {
        ColorTheme.named(themeID)
    }

    // MARK: - Dove chiedere

    /// L'indirizzo del relay e il nome con cui chiedergli lo stato, per chi deve
    /// andarselo a prendere invece di aspettare che glielo depositino.
    ///
    /// **Qui e non nel portachiavi, di proposito.** Il paragrafo sopra dice che in
    /// questo contenitore non entra nessuna chiave, e continua a valere: con
    /// queste due stringhe si ottiene soltanto la scatola sigillata, che senza la
    /// chiave non si apre. Chi le rubasse avrebbe del rumore cifrato. La chiave
    /// resta dove deve stare — nel portachiavi, e la legge `IslandKey`.
    ///
    /// Le scrive l'app a ogni lettura riuscita, così restano vere anche dopo che
    /// l'utente cambia relay o rifà l'accoppiamento.
    public static var relayCoordinates: (url: String, pairID: String)? {
        guard let defaults = UserDefaults(suiteName: groupID),
              let url = defaults.string(forKey: relayURLKey), !url.isEmpty,
              let pairID = defaults.string(forKey: pairIDKey), !pairID.isEmpty
        else { return nil }
        return (url, pairID)
    }

    public static func rememberRelay(url: String, pairID: String) {
        guard let defaults = UserDefaults(suiteName: groupID) else { return }
        defaults.set(url, forKey: relayURLKey)
        defaults.set(pairID, forKey: pairIDKey)
    }

    /// Scordate allo scollegamento: un widget che continuasse a interrogare il
    /// relay di un accoppiamento disfatto prenderebbe 401 per sempre, e lo
    /// direbbe all'utente come se fosse un guasto.
    public static func forgetRelay() {
        guard let defaults = UserDefaults(suiteName: groupID) else { return }
        defaults.removeObject(forKey: relayURLKey)
        defaults.removeObject(forKey: pairIDKey)
    }

    // MARK: - Diagnosi

    /// Perché il contenuto manca, quando manca. `nil` se c'è e si legge.
    ///
    /// Esiste per un motivo preciso: quando l'isola non riusciva a leggere il
    /// suo contenuto mostrava **trattini**, e trovarne la causa è costato cinque
    /// tentativi perché tre guasti diversi si vedevano identici. Un widget muto
    /// sarebbe lo stesso errore rifatto. Tre frasi, una per causa, disegnate
    /// piccole in fondo al widget.
    public static func diagnosis() -> String? {
        guard let url = islandURL else {
            // L'autorizzazione al gruppo manca o non è arrivata nel profilo di
            // firma: nessuna quantità di attesa la risolve.
            return "gruppo condiviso non raggiungibile"
        }
        guard let data = try? Data(contentsOf: url) else {
            // Il gruppo c'è ma nessuno ha ancora scritto: l'app non è mai stata
            // aperta dopo l'aggiornamento, o non è accoppiata.
            return "apri l'app una volta"
        }
        guard (try? JSONDecoder().decode(ClaudeIslandState.self, from: data)) != nil else {
            // Scritto da una versione che diceva le cose in un altro modo.
            return "dato condiviso illeggibile"
        }
        return nil
    }
}
#endif
