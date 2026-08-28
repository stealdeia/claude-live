#if os(iOS)
import CryptoKit
import Foundation
import Security

/// La chiave dell'accoppiamento, in un posto dove anche l'estensione dell'isola
/// possa leggerla.
///
/// ## Perché una copia e non la stessa voce
///
/// La chiave dell'app sta in una voce del portachiavi che l'app usa da sempre.
/// Aggiungerle un gruppo condiviso vorrebbe dire toccare quella voce — e una
/// voce che dopo la modifica non si ritrova più è un accoppiamento perso, da
/// rifare col QR. Quindi qui c'è una **copia** in una voce nuova: se qualcosa va
/// storto, va storta la copia, e l'app continua a funzionare come prima.
///
/// La scrive l'app a ogni avvio, la legge l'estensione quando deve aprire un
/// contenuto arrivato per notifica. Se non c'è, l'isola mostra quello che
/// sapeva già: meglio un numero vecchio che una schermata rotta.
public enum IslandKey {
    private static let service = "it.aldeialab.ClaudeLive.island"
    private static let account = "encryptionKey"

    /// Il gruppo condiviso, senza il prefisso scritto a mano.
    ///
    /// Prima era `"G7PDRQRC29.it.aldeialab.ClaudeLiveMobile.shared"`, col prefisso
    /// copiato dall'identificativo della squadra. Ma il prefisso delle
    /// autorizzazioni — quello che Xcode scrive al posto di
    /// `$(AppIdentifierPrefix)` — **non è per definizione** l'identificativo della
    /// squadra: su alcuni account differisce, e se differisce ogni chiamata al
    /// portachiavi fallisce con «autorizzazione mancante». Silenziosamente:
    /// l'isola mostrava trattini e nessuno diceva perché.
    ///
    /// Ora il prefisso lo dice il sistema. Il modo è indiretto perché non esiste
    /// un'interfaccia pubblica che lo chieda: si scrive una voce **senza**
    /// dichiarare il gruppo — allora il sistema usa quello predefinito, che è
    /// `prefisso.identificativo-del-pacchetto` — e la si rilegge per sapere quale
    /// ha usato. Un giro strano per una cosa semplice, ma è un fatto letto invece
    /// che una stringa sperata.
    private static let sharedSuffix = "it.aldeialab.ClaudeLiveMobile.shared"

    private static var cachedGroup: String?

    static func accessGroup() -> String? {
        if let cachedGroup { return cachedGroup }
        guard let prefix = identifierPrefix() else { return nil }
        let group = prefix + sharedSuffix
        cachedGroup = group
        return group
    }

    /// Il prefisso delle autorizzazioni, punto finale compreso.
    private static func identifierPrefix() -> String? {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "prefix-probe",
        ]
        SecItemDelete(probe as CFDictionary)

        var insert = probe
        insert[kSecValueData as String] = Data([0])
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { return nil }

        var read = probe
        read[kSecReturnAttributes as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        SecItemDelete(probe as CFDictionary)

        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String,
              let dot = group.firstIndex(of: ".")
        else { return nil }
        return String(group[group.startIndex...dot])
    }

    /// Mette a disposizione dell'estensione la chiave che l'app ha già.
    ///
    /// Restituisce `false` quando non ci riesce, e il chiamante lo dice: era
    /// `@discardableResult` e nessuno lo guardava, quindi un fallimento qui si
    /// vedeva soltanto come un'isola piena di trattini.
    public static func share(_ exportedKey: String) -> Bool {
        guard let data = exportedKey.data(using: .utf8),
              let accessGroup = accessGroup()
        else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = data
        // Dopo il primo sblocco, e solo su questo telefono.
        //
        // **Non** «da sbloccato»: era la mia scelta iniziale, con la
        // giustificazione che «l'isola si disegna a schermo acceso». Ma schermo
        // acceso non è sbloccato, e la Live Activity sulla schermata di blocco
        // viene disegnata proprio mentre il telefono è bloccato — quindi la
        // chiave non si trovava, la scatola non si apriva, e l'isola mostrava
        // trattini al posto dei numeri. Visto il 2026-08-27.
        //
        // «Dopo il primo sblocco» è il minimo che permette di lavorare a telefono
        // bloccato: da riavviato e mai sbloccato la chiave resta inaccessibile.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { return false }
        // Riletta subito. Scrivere e credere è come non aver scritto: è
        // esattamente il passaggio che mancava, e per due giri di prove ha
        // lasciato l'isola muta senza dire niente a nessuno.
        return read() != nil
    }

    /// La chiave, per chi deve aprire una scatola sigillata.
    ///
    /// L'estensione non dichiara nessun gruppo perché non le serve: il suo unico
    /// gruppo autorizzato *è* quello condiviso, quindi il predefinito coincide.
    /// L'app invece lo dichiara, perché il suo predefinito è un altro.
    public static func read() -> SymmetricKey? {
        // Senza dichiarare il gruppo, prima.
        //
        // In una ricerca il gruppo si può omettere, e allora il sistema guarda in
        // *tutti* quelli a cui il chiamante ha diritto — che è esattamente quello
        // che serve, sia all'app sia all'estensione. Dichiararlo costringeva a
        // chiamare `accessGroup()`, che per scoprire il prefisso **scrive** una
        // voce di prova, la rilegge e la cancella: tre operazioni sul portachiavi
        // a ogni singolo disegno dell'isola, dentro un'estensione che il sistema
        // fa girare con poco tempo e poca memoria. Una scrittura sul percorso di
        // lettura è lavoro che può fallire, e quando falliva l'isola restava a
        // trattini senza dire niente a nessuno.
        //
        // Il giro col gruppo resta come riserva, per il caso in cui la ricerca
        // larga non trovi niente.
        if let key = readKey(inGroup: nil) { return key }
        guard let group = accessGroup() else { return nil }
        return readKey(inGroup: group)
    }

    private static func readKey(inGroup group: String?) -> SymmetricKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return try? RemoteCrypto.importKey(text)
    }

    // MARK: - L'ultimo contenuto buono

    private static let lastGoodAccount = "lastGoodIsland"

    /// Mette da parte l'ultimo contenuto che si è riusciti a leggere.
    ///
    /// Perché esiste: quando l'estensione non riesce ad aprire la scatola
    /// sigillata che arriva per notifica, prima mostrava un'isola **vuota** —
    /// cioè trattini al posto dei numeri, e nessun modo di sapere perché. Un dato
    /// di qualche minuto fa dice ancora qualcosa di vero, e comunque c'è la
    /// scadenza che lo fa sbiadire da sé: è meglio di niente in ogni caso.
    ///
    /// Lo scrive l'app, che il contenuto ce l'ha in chiaro e sa quando cambia.
    /// L'estensione soltanto lo legge: scrivere mentre si disegna è il lavoro che
    /// abbiamo appena tolto da quel percorso.
    public static func rememberLastGood(_ island: ClaudeIslandState) {
        guard let data = try? JSONEncoder().encode(island),
              let accessGroup = accessGroup()
        else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: lastGoodAccount,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    /// L'ultimo contenuto buono, per quando la scatola non si apre.
    public static func lastGood() -> ClaudeIslandState? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: lastGoodAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(ClaudeIslandState.self, from: data)
    }

    public static func forget() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = accessGroup() { query[kSecAttrAccessGroup as String] = group }
        SecItemDelete(query as CFDictionary)

        var stored: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: lastGoodAccount,
        ]
        if let group = accessGroup() { stored[kSecAttrAccessGroup as String] = group }
        SecItemDelete(stored as CFDictionary)
    }
}
#endif
