import Foundation
import Security
import CryptoKit


/// The two secrets the companion needs, kept in the Keychain.
///
/// Not in `settings.json`, which is a plain file in Application Support: the
/// encryption key is the one thing standing between a stolen relay payload and
/// its contents, and a file anyone can read is not where it belongs.
///
/// Our own Keychain item, unlike the Claude Code credentials this app only
/// reads — so it is created, updated and deleted here.
public enum RemoteSecrets {
    private static let service = "it.aldeialab.ClaudeLive.remote"

    public enum Item: String {
        /// This pair's own identifier: its corner of the relay, and the credential
        /// for reaching it.
        case pairID
        /// Never leaves the Mac except by QR: what actually protects the payload.
        case encryptionKey
        /// L'indirizzo del relay. Non è un segreto, ma è il terzo pezzo
        /// dell'accoppiamento e deve stare dove stanno gli altri due.
        ///
        /// Stava nelle preferenze, che dopo un riavvio del telefono e prima del
        /// primo sblocco rispondono «vuoto» invece di «non lo so». Tre pezzi letti
        /// da due posti con due comportamenti diversi davanti a un telefono
        /// bloccato erano tre modi di sbagliare la stessa domanda.
        case relayURL
    }

    /// Cosa dice il portachiavi, che non è sempre «sì» o «no».
    ///
    /// La distinzione è tutta qui, e non averla era un difetto vero: prima del
    /// primo sblocco dopo un riavvio, una voce protetta esiste ma **non si può
    /// leggere**. Trattare quel «non adesso» come un «non c'è» faceva dire
    /// all'app di non essere accoppiata — e sul Mac, dove le chiavi vengono
    /// generate a richiesta, avrebbe fatto di peggio: ne avrebbe scritte di nuove
    /// sopra quelle buone.
    public enum Lookup: Equatable {
        case found(String)
        /// Il portachiavi ha risposto: quella voce non c'è.
        case absent
        /// Il portachiavi non può rispondere adesso — di norma perché il telefono
        /// non è ancora stato sbloccato dopo un riavvio. Non conclude niente.
        case unavailable(OSStatus)
    }

    public static func look(_ item: Item) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let text = String(data: data, encoding: .utf8) {
            return .found(text)
        }
        if status == errSecItemNotFound { return .absent }
        // Qualunque altro esito: `errSecInteractionNotAllowed` davanti a un
        // telefono bloccato, ma anche un guasto che non sappiamo nominare. In
        // entrambi i casi la risposta onesta è «non lo so», non «non c'è».
        return .unavailable(status)
    }

    public static func read(_ item: Item) -> String? {
        guard case .found(let text) = look(item) else { return nil }
        return text
    }

    @discardableResult
    public static func write(_ value: String, to item: Item) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
        // Delete then add rather than update: an update on a missing item fails,
        // and the two-step keeps the accessibility attribute from being inherited
        // from whatever was there before.
        SecItemDelete(base as CFDictionary)

        var insert = base
        insert[kSecValueData as String] = Data(value.utf8)
        // Available only once the Mac has been unlocked, and never synchronised
        // to iCloud: the phone gets this key by QR, deliberately, so that giving
        // it away stays an act rather than a default.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(insert as CFDictionary, nil)
        // The caller logs: this package has no logger, deliberately — it is
        // shared with an app that has a different one.
        if status != errSecSuccess {

        }
        return status == errSecSuccess
    }

    public static func delete(_ item: Item) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Se l'accoppiamento c'è, dati i tre responsi del portachiavi.
    ///
    /// `nil` significa «non lo so», ed è il valore che non c'era: prima del primo
    /// sblocco dopo un riavvio le voci esistono ma non si leggono, e trattare quel
    /// silenzio come un «no» faceva chiedere di nuovo il codice QR con le chiavi
    /// intatte a un centimetro di distanza.
    ///
    /// Funzione pura e fuori dall'app perché è la parte che ha sbagliato: prende
    /// dei responsi e restituisce una conclusione, quindi si può provare senza un
    /// telefono e senza un portachiavi.
    ///
    /// `legacyRelayURL` è l'indirizzo come stava nelle preferenze prima che si
    /// trasferisse qui: chi aggiorna l'app ce l'ha ancora solo là.
    public static func pairingIsComplete(
        pairID: Lookup,
        encryptionKey: Lookup,
        relayURL: Lookup,
        legacyRelayURL: String?
    ) -> Bool? {
        var unknown = false
        for found in [pairID, encryptionKey] {
            switch found {
            case .found(let value) where !value.isEmpty: continue
            // Basta che uno dei due manchi davvero per concludere di no: un
            // accoppiamento a metà non è un accoppiamento.
            case .found, .absent: return false
            case .unavailable: unknown = true
            }
        }

        switch relayURL {
        case .found(let url) where !url.isEmpty: return unknown ? nil : true
        case .unavailable: return nil
        case .found, .absent:
            // Senza indirizzo nuovo vale quello vecchio, se c'è.
            if !(legacyRelayURL ?? "").isEmpty { return unknown ? nil : true }
            // Nessun indirizzo da nessuna parte. Se i segreti erano illeggibili
            // non si conclude comunque: potrebbe esserlo anche l'indirizzo.
            return unknown ? nil : false
        }
    }

    // MARK: - Comodità

    /// The key, generating and storing one the first time it is asked for.
    public static func encryptionKey() -> SymmetricKey? {
        switch look(.encryptionKey) {
        case .found(let stored):
            if let key = try? RemoteCrypto.importKey(stored) { return key }
        case .unavailable:
            // Non si genera al buio: sovrascriverebbe la chiave vera con una
            // nuova, e l'accoppiamento sarebbe perso davvero invece che solo
            // illeggibile per qualche istante.
            return nil
        case .absent:
            break
        }
        let fresh = RemoteCrypto.newKey()
        guard write(RemoteCrypto.export(fresh), to: .encryptionKey) else { return nil }

        return fresh
    }

    /// This pair's identifier, generating and storing one the first time it is asked for.
    ///
    /// It replaces the shared password the relay used to check, and it is both the
    /// address of this pair's data and the permission to touch it. A password
    /// common to every installation could be neither: it authorises everybody for
    /// everything, and it has to *arrive* somewhere — typed by hand, which nobody
    /// will do, or shipped inside the app, where anyone can read it out.
    ///
    /// 128 bits, so it cannot be guessed. What it does not do is protect the
    /// contents, and nothing at the relay could: those are sealed with a key that
    /// never leaves these two devices.
    public static func pairID() -> String? {
        switch look(.pairID) {
        case .found(let stored):
            if stored.count == 32 { return stored }
        case .unavailable:
            return nil
        case .absent:
            break
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { return nil }
        let fresh = bytes.map { String(format: "%02x", $0) }.joined()
        guard write(fresh, to: .pairID) else { return nil }
        return fresh
    }

    /// Forgets everything, so a new phone starts from a clean pairing.
    ///
    /// The identifier goes too: a phone that kept the old one would still be
    /// holding a valid address, and unpairing has to mean something.
    public static func reset() {
        delete(.pairID)
        delete(.encryptionKey)
        delete(.relayURL)
    }
}
