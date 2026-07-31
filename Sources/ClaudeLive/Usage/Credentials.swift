import Foundation
import Security

/// The OAuth credentials Claude Code stores in the login keychain.
///
/// Verified empirically on this machine: a generic-password item with
/// service `Claude Code-credentials`, whose data is JSON shaped like
///
/// ```json
/// { "claudeAiOauth": {
///     "accessToken": "sk-ant-oat01-…",
///     "refreshToken": "sk-ant-ort01-…",
///     "expiresAt": 1785508744214,            // ms since epoch
///     "refreshTokenExpiresAt": 1786341134214,
///     "scopes": ["user:inference", …],
///     "subscriptionType": "team",
///     "rateLimitTier": "default_claude_max_5x"
///   },
///   "organizationUuid": "…" }
/// ```
struct ClaudeCredentials: Sendable {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
    let rateLimitTier: String?
    let organizationUUID: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        // 60s of slack: a token about to die is treated as already dead so we
        // re-read the keychain instead of burning a request on a 401.
        return expiresAt.timeIntervalSinceNow < 60
    }
}

enum CredentialsError: LocalizedError {
    /// No keychain item at all — the user has never logged in with Claude Code.
    case notFound
    /// The item exists but macOS denied us access (user clicked "Deny").
    case accessDenied(OSStatus)
    case keychainFailure(OSStatus)
    case malformedPayload(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Credenziali Claude Code non trovate nel Keychain. Apri il Terminale, esegui `claude` ed effettua il login."
        case .accessDenied:
            return "Accesso al Keychain negato. Rimuovi la voce di negazione da Accesso Portachiavi, o riavvia Claude Live e scegli «Consenti sempre»."
        case .keychainFailure(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "codice \(status)"
            return "Errore Keychain: \(detail)"
        case .malformedPayload(let detail):
            return "Credenziali in formato inatteso: \(detail)"
        }
    }
}

/// Read-only access to Claude Code's credentials.
///
/// Deliberately **never writes** to the keychain and **never calls the OAuth
/// refresh endpoint**: refreshing rotates the refresh token, which would
/// invalidate the copy Claude Code itself holds and break the user's CLI login.
/// When the access token expires we simply re-read the item — Claude Code
/// refreshes it on its own next run.
///
/// **Never call `load()` from the main thread.** `SecItemCopyMatching` blocks the
/// calling thread for as long as macOS is showing its "allow access to this
/// keychain item?" dialog — which happens on first launch and again after every
/// rebuild that changes the code signature. Blocking the main thread there
/// freezes the entire app: timers, file watchers, panel updates, everything.
enum CredentialsStore {
    /// The primary item. Claude Code also keeps per-workspace variants named
    /// `Claude Code-credentials-<hash>`; we try those as a fallback.
    private static let primaryService = "Claude Code-credentials"

    static func load() throws -> ClaudeCredentials {
        var lastError: CredentialsError = .notFound

        for service in candidateServices() {
            do {
                let data = try readItem(service: service)
                let credentials = try parse(data)
                Log.debug(
                    "Credenziali lette da «\(service)» (piano: \(credentials.subscriptionType ?? "?"), tier: \(credentials.rateLimitTier ?? "?"))",
                    category: .keychain
                )
                return credentials
            } catch let error as CredentialsError {
                lastError = error
                switch error {
                case .notFound:
                    continue // try the next candidate service name
                default:
                    throw error // access denied / malformed: don't mask it
                }
            }
        }

        throw lastError
    }

    /// Primary name first, then any `Claude Code-credentials*` items present.
    private static func candidateServices() -> [String] {
        var services = [primaryService]

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return services
        }

        let extra = items
            .compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0.hasPrefix(primaryService) && $0 != primaryService }
            .sorted()
        services.append(contentsOf: extra)
        return services
    }

    private static func readItem(service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw CredentialsError.malformedPayload("payload keychain vuoto")
            }
            return data
        case errSecItemNotFound:
            throw CredentialsError.notFound
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw CredentialsError.accessDenied(status)
        default:
            throw CredentialsError.keychainFailure(status)
        }
    }

    private static func parse(_ data: Data) throws -> ClaudeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialsError.malformedPayload("JSON non valido")
        }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw CredentialsError.malformedPayload("chiave claudeAiOauth assente")
        }
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw CredentialsError.malformedPayload("accessToken assente")
        }

        // Stored in milliseconds since epoch.
        let expiresAt = (oauth["expiresAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }

        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String,
            organizationUUID: root["organizationUuid"] as? String
        )
    }
}
