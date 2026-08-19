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
    /// Used to obtain a new access token without Claude Code having to run.
    /// Optional because an item written by an older CLI may not carry one.
    let refreshToken: String?
    let expiresAt: Date?
    let subscriptionType: String?
    let rateLimitTier: String?
    let organizationUUID: String?
    /// The keychain service this was read from (diagnostics: the primary item
    /// or one of the per-workspace variants).
    let service: String
    /// The item's payload exactly as Claude Code wrote it, for fields we do not
    /// model.
    let rawPayload: Data

    /// Whether the stated expiry has passed.
    ///
    /// **Informational only — never a reason not to try.** This used to gate the
    /// probe, and the result was an app that went silent for half an hour: at
    /// 09:44 it refused to use a token good until 09:48, then sat idle until
    /// Claude Code happened to refresh it at 10:14, reading the keychain every
    /// five minutes and never once asking the server. Whether a token still works
    /// is the server's answer, not ours.
    var isPastExpiry: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow <= 0
    }

    /// Same credentials with a token the API is guaranteed to refuse.
    ///
    /// Diagnostic only, for `CLAUDELIVE_FORCE_BAD_TOKEN=1`: the handling of a
    /// refused token has now been wrong twice, and waiting eight hours for a real
    /// expiry is not a way to test it.
    func withInvalidToken() -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: accessToken + "-non-valido",
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier,
            organizationUUID: organizationUUID,
            service: service,
            rawPayload: rawPayload
        )
    }
}

/// Runs a blocking keychain call off the Swift concurrency thread pool.
///
/// `Task.detached` was the obvious choice and the wrong one. It runs on the
/// cooperative pool, and `SecItemCopyMatching` *blocks* its thread for as long
/// as macOS keeps its "allow access?" dialog on screen. With pool threads held
/// that way, even the `Task.sleep` implementing our own timeout could not get
/// scheduled — observed live on 2026-08-06, when a single dialog froze the
/// polling loop for **27 minutes** and every poll in between logged
/// "già in corso". A dedicated queue keeps the blocking where it starves
/// nothing else.
enum KeychainQueue {
    /// **Serial on purpose.** `authorizationState()` turns user interaction off for
    /// the whole process while it probes, so a real read running at the same time
    /// would be failed in silence instead of raising its dialog — a spurious "no
    /// credentials" caused by the diagnostic meant to explain them. Nothing here
    /// needs to run in parallel: it is one keychain, and a read that puts a dialog on
    /// screen should hold the queue until it is answered.
    private static let queue = DispatchQueue(
        label: "it.aldeialab.ClaudeLive.keychain",
        qos: .utility
    )

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
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

/// Whether macOS will let us read the item without asking the user first.
enum KeychainAuthorization: Equatable {
    /// Readable in silence.
    case granted
    /// The item is there, but this copy of the app is not authorised for it: the
    /// next real read raises the password dialog — or fails outright, if the user
    /// once answered "Deny".
    case notAuthorized
    case notFound
    case failed(OSStatus)

    var isGranted: Bool { self == .granted }
}

/// **Read-only** access to Claude Code's credentials — permanently.
///
/// Writing was allowed exactly once, in 0.5.1, to renew expired tokens, and the
/// morning of 2026-08-07 showed why it must never be again. Claude Code keeps
/// its refresh token *in memory*, so however carefully we rotated and stored,
/// its copy died with every renewal: the CLI logged the user out, the user
/// logged back in (invalidating *our* token), and the resulting 401→renew loop
/// rewrote the keychain every five minutes — each write raising the macOS
/// password dialog. The token family has one owner and it is not us. When the
/// token expires, this app waits for Claude Code to write a fresh one (see
/// UsageMonitor's recovery watch) and reads it; it never renews.
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

    /// When Claude Code last wrote the item, or nil if it cannot be determined.
    ///
    /// This is the cheap half of the story: an **attributes-only** query decrypts
    /// nothing, so it never consults the item's ACL and can never raise the "allow
    /// access?" dialog. That makes it safe to call on every poll, and it is what
    /// lets the payload be read only when there is genuinely something new —
    /// exactly once per token refresh instead of once per poll.
    static func modificationDate() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: primaryService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any]
        else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    /// Asks whether a read would be allowed, **without ever showing a dialog**.
    ///
    /// Exists because the dialog was indistinguishable from a mystery. The keychain
    /// authorises by **path**: the entry lists `/Applications/Claude Live.app`, so a
    /// copy run from anywhere else — a build directory, a disk image, the Downloads
    /// folder — is a different application as far as the keychain is concerned, and
    /// "Always allow" granted to one says nothing about the other. That is invisible
    /// from the outside: the app looks identical and the dialog looks random.
    ///
    /// `SecKeychainSetUserInteractionAllowed(false)` is what makes this safe to run
    /// whenever we like: with interaction off, a read that would have prompted fails
    /// with `errSecInteractionNotAllowed` instead. It is process-global, hence the
    /// immediate restore.
    static func authorizationState() -> KeychainAuthorization {
        // The tool is tried first because the real read does, with a short timeout:
        // a prompt raised by `security` would leave it waiting, and a probe must
        // never block.
        if let _ = try? readItemViaSecurityTool(service: primaryService, timeout: 2) {
            return .granted
        }

        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }

        do {
            _ = try readItemDirectly(service: primaryService)
            return .granted
        } catch CredentialsError.notFound {
            return .notFound
        } catch CredentialsError.accessDenied(let status) {
            // Two codes mean the same thing here, and the difference was found by
            // running the probe from an unauthorised path: `interactionNotAllowed`
            // is "would have asked", `authFailed` is what the keychain actually
            // returns when the requesting binary is not on the item's list. Treating
            // only the first as "not authorised" reported the second as an internal
            // error — the very confusion this probe exists to remove.
            switch status {
            case errSecInteractionNotAllowed, errSecAuthFailed: return .notAuthorized
            default: return .failed(status)
            }
        } catch let error as CredentialsError {
            if case .keychainFailure(let status) = error { return .failed(status) }
            return .failed(errSecInternalError)
        } catch {
            return .failed(errSecInternalError)
        }
    }

    /// Reads the payload by asking `/usr/bin/security`, the way Claude Code does.
    ///
    /// ## Why not `SecItemCopyMatching` first
    ///
    /// Because "Allow always" cannot hold, and the reason is not macOS being
    /// difficult: **Claude Code rewrites this item on every token refresh, and the
    /// write resets the item's access list.** Measured on 2026-08-19: the item was
    /// written at 09:47:02, and our next read raised the password dialog at 09:48:51
    /// — from `/Applications/Claude Live.app`, the very path that had read it in
    /// silence nine minutes earlier. The grant is destroyed by the item's owner, so
    /// no amount of clicking "Always" survives a token refresh, and a token refresh
    /// happens every few hours.
    ///
    /// The one entry that always survives is `/usr/bin/security` itself, because it
    /// is the tool doing the writing and is re-added by every write — which is also
    /// why Claude Code never gets asked. Routing the read through it makes the
    /// request come from an application that is authorised by construction: measured
    /// at 46 ms with no dialog.
    ///
    /// The payload is never logged, and `-w` writes it to a pipe rather than to a
    /// file, so it does not touch the disk.
    private static func readItemViaSecurityTool(service: String, timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw CredentialsError.keychainFailure(errSecInternalError)
        }

        // Read before waiting: a payload larger than the pipe buffer would deadlock
        // a process we are waiting on.
        let data = output.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            // Only reachable if the tool itself was left waiting for an answer.
            process.terminate()
            throw CredentialsError.accessDenied(errSecInteractionNotAllowed)
        }

        guard process.terminationStatus == 0 else {
            // 44 is the tool's "item not found"; anything else is a refusal.
            throw process.terminationStatus == 44
                ? CredentialsError.notFound
                : CredentialsError.accessDenied(errSecAuthFailed)
        }

        guard var text = String(data: data, encoding: .utf8) else {
            throw CredentialsError.malformedPayload("uscita di security non leggibile")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw CredentialsError.malformedPayload("uscita di security vuota")
        }

        // `security` prints text passwords as they are and binary ones as hex, and
        // which one we get is not ours to decide.
        if text.hasPrefix("{") {
            return Data(text.utf8)
        }
        if let decoded = Data(hexEncoded: text) {
            return decoded
        }
        return Data(text.utf8)
    }

    static func load() throws -> ClaudeCredentials {
        // Try the primary item on its own first. Claude Code accumulates a lot of
        // `Claude Code-credentials-<hash>` variants (18 on the development
        // machine), and every extra item read is another chance for macOS to
        // raise its access dialog — so they are only consulted if the primary
        // genuinely is not there.
        do {
            return try loadItem(service: primaryService)
        } catch CredentialsError.notFound {
            // Fall through to the variants.
        }

        var lastError: CredentialsError = .notFound

        for service in variantServices() {
            do {
                return try loadItem(service: service)
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

    private static func loadItem(service: String) throws -> ClaudeCredentials {
        let credentials = try parse(readItem(service: service), service: service)
        Log.debug(
            "Credenziali lette da «\(service)» (piano: \(credentials.subscriptionType ?? "?"), tier: \(credentials.rateLimitTier ?? "?"))",
            category: .keychain
        )
        return credentials
    }

    /// The `Claude Code-credentials-<hash>` items, if any.
    private static func variantServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items
            .compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0.hasPrefix(primaryService) && $0 != primaryService }
            .sorted()
    }

    /// The tool first, the framework as a fallback.
    ///
    /// The fallback matters: `/usr/bin/security` is authorised because Claude Code's
    /// writes keep it authorised, and that is an implementation detail of somebody
    /// else's program. If it ever stops being true, a direct read still works — it
    /// just may ask.
    private static func readItem(service: String) throws -> Data {
        do {
            let data = try readItemViaSecurityTool(service: service, timeout: 25)
            Log.debug("Payload letto tramite /usr/bin/security", category: .keychain)
            return data
        } catch CredentialsError.notFound {
            throw CredentialsError.notFound
        } catch {
            Log.debug(
                "Lettura tramite /usr/bin/security non riuscita, uso l'API diretta: \(error.localizedDescription)",
                category: .keychain
            )
        }
        return try readItemDirectly(service: service)
    }

    private static func readItemDirectly(service: String) throws -> Data {
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

    private static func parse(_ data: Data, service: String) throws -> ClaudeCredentials {
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

        let refreshToken = (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        return ClaudeCredentials(
            accessToken: token,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String,
            organizationUUID: root["organizationUuid"] as? String,
            service: service,
            rawPayload: data
        )
    }

}


private extension Data {
    /// `security` prints binary passwords as hex digits.
    init?(hexEncoded string: String) {
        let characters = Array(string.utf8)
        guard characters.count % 2 == 0, !characters.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        func value(_ character: UInt8) -> UInt8? {
            switch character {
            case 0x30...0x39: return character - 0x30
            case 0x61...0x66: return character - 0x61 + 10
            case 0x41...0x46: return character - 0x41 + 10
            default: return nil
            }
        }
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let high = value(characters[index]),
                  let low = value(characters[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        self = Data(bytes)
    }
}
