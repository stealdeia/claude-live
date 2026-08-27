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

    /// Il gruppo del portachiavi condiviso fra app ed estensione.
    ///
    /// Il prefisso è l'identificativo della squadra, scritto per esteso: nelle
    /// autorizzazioni si usa `$(AppIdentifierPrefix)`, che Xcode espande, ma a
    /// tempo di esecuzione la ricerca vuole la stringa intera. È lo stesso valore
    /// che sta in `release.conf`, e cambia solo se cambia l'account Apple.
    private static let accessGroup = "G7PDRQRC29.it.aldeialab.ClaudeLiveMobile.shared"

    /// Mette a disposizione dell'estensione la chiave che l'app ha già.
    @discardableResult
    public static func share(_ exportedKey: String) -> Bool {
        guard let data = exportedKey.data(using: .utf8) else { return false }
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
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// La chiave, per chi deve aprire una scatola sigillata.
    public static func read() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return try? RemoteCrypto.importKey(text)
    }

    public static func forget() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ] as CFDictionary)
    }
}
#endif
