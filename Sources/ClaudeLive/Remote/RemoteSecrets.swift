import Foundation
import Security
import CryptoKit
import ClaudeLiveKit

/// The two secrets the companion needs, kept in the Keychain.
///
/// Not in `settings.json`, which is a plain file in Application Support: the
/// encryption key is the one thing standing between a stolen relay payload and
/// its contents, and a file anyone can read is not where it belongs.
///
/// Our own Keychain item, unlike the Claude Code credentials this app only
/// reads — so it is created, updated and deleted here.
enum RemoteSecrets {
    private static let service = "it.aldeialab.ClaudeLive.remote"

    enum Item: String {
        /// Shared with the relay: proves a request comes from our devices.
        case pairSecret
        /// Never leaves the Mac except by QR: what actually protects the payload.
        case encryptionKey
    }

    static func read(_ item: Item) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    @discardableResult
    static func write(_ value: String, to item: Item) -> Bool {
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
        if status != errSecSuccess {
            Log.error("Salvataggio del segreto «\(item.rawValue)» fallito: \(status)")
        }
        return status == errSecSuccess
    }

    static func delete(_ item: Item) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Comodità

    /// The key, generating and storing one the first time it is asked for.
    static func encryptionKey() -> SymmetricKey? {
        if let stored = read(.encryptionKey), let key = try? RemoteCrypto.importKey(stored) {
            return key
        }
        let fresh = RemoteCrypto.newKey()
        guard write(RemoteCrypto.export(fresh), to: .encryptionKey) else { return nil }
        Log.info("Generata una nuova chiave di cifratura per il companion")
        return fresh
    }

    /// Forgets everything, so a new phone starts from a clean pairing.
    static func reset() {
        delete(.pairSecret)
        delete(.encryptionKey)
    }
}
