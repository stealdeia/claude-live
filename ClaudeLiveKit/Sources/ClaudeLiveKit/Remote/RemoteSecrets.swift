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
    }

    public static func read(_ item: Item) -> String? {
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

    // MARK: - Comodità

    /// The key, generating and storing one the first time it is asked for.
    public static func encryptionKey() -> SymmetricKey? {
        if let stored = read(.encryptionKey), let key = try? RemoteCrypto.importKey(stored) {
            return key
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
        if let stored = read(.pairID), stored.count == 32 { return stored }

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
    }
}
