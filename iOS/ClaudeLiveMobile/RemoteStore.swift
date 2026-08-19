import Foundation
import UserNotifications
import UIKit
import CryptoKit
import ClaudeLiveKit

/// Reads what the Mac published, and decrypts it.
///
/// Asks rather than listens. A phone spends most of its life asleep and without
/// a socket, so a connection it believes it has is usually a connection it does
/// not: fetching on demand means the app can never think it is up to date when
/// it is not.
@MainActor
final class RemoteStore: ObservableObject {

    @Published private(set) var snapshot: RemoteSnapshot?
    @Published private(set) var problem: String?
    @Published private(set) var isPaired: Bool

    /// The relay's address. Not secret; the password and key are in the Keychain.
    private var relayURL: String {
        get { UserDefaults.standard.string(forKey: "relayURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "relayURL") }
    }

    private var refreshTask: Task<Void, Never>?

    init() {
        isPaired = RemoteSecrets.read(.pairSecret) != nil
            && RemoteSecrets.read(.encryptionKey) != nil
            && !(UserDefaults.standard.string(forKey: "relayURL") ?? "").isEmpty
    }

    // MARK: - Accoppiamento

    /// Consumes the QR the Mac shows: address, password and key in one act.
    @discardableResult
    func pair(withPayload payload: String) -> Bool {
        guard let data = payload.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let url = fields["url"], !url.isEmpty,
              let secret = fields["secret"], !secret.isEmpty,
              let key = fields["key"],
              // Validated before being stored: a malformed key saved now would
              // fail later as an unopenable payload, which reads as a network
              // problem and sends you looking in the wrong place.
              (try? RemoteCrypto.importKey(key)) != nil
        else {
            problem = "Codice non valido."
            return false
        }

        relayURL = url
        RemoteSecrets.write(secret, to: .pairSecret)
        RemoteSecrets.write(key, to: .encryptionKey)
        isPaired = true
        problem = nil

        // Pairing is also when this phone says where to reach it. Without this
        // the app reads perfectly and is never told anything: the Mac publishes,
        // the relay has no address to push to, and you find out only by opening
        // the app on a hunch — which is the one thing it exists to avoid.
        Task { await requestPushPermission() }
        Task { await refresh() }
        return true
    }

    // MARK: - Notifiche

    func requestPushPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                problem = "Notifiche negate: l'app non potrà avvisarti."
                return
            }
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        } catch {
            problem = "Permesso notifiche non concesso: \(error.localizedDescription)"
        }
    }

    /// The address APNs gave this phone, handed to the relay.
    func registerDevice(token: Data) async {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard isPaired,
              let url = URL(string: relayURL + "/register"),
              let secret = RemoteSecrets.read(.pairSecret)
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["deviceToken": hex])
        request.timeoutInterval = 15

        // Re-sent on every launch, not only at pairing: iOS may hand out a new
        // token after a reinstall or a restore, and a stale one on the relay
        // fails silently — APNs accepts the request and delivers to nobody.
        _ = try? await URLSession.shared.data(for: request)
    }

    func unpair() {
        RemoteSecrets.reset()
        relayURL = ""
        snapshot = nil
        isPaired = false
        problem = nil
    }

    // MARK: - Lettura

    func refresh() async {
        guard isPaired else { return }
        guard let url = URL(string: relayURL + "/state"),
              let secret = RemoteSecrets.read(.pairSecret),
              let keyText = RemoteSecrets.read(.encryptionKey),
              let key = try? RemoteCrypto.importKey(keyText)
        else {
            problem = "Accoppiamento incompleto."
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = 15
        // Always from the network: a status that is quietly served from a cache
        // is the one failure this app must never have.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0

            switch code {
            case 200:
                break
            case 404:
                problem = "Il Mac non ha ancora pubblicato nulla."
                return
            case 401:
                problem = "Il relay ha rifiutato la parola d'ordine."
                return
            default:
                problem = "Il relay ha risposto \(code)."
                return
            }

            guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = body["payload"] as? String
            else {
                problem = "Risposta del relay illeggibile."
                return
            }

            snapshot = try RemoteCrypto.open(RemoteSnapshot.self, from: payload, with: key)
            problem = nil

        } catch let failure as RemoteCrypto.Failure {
            // Not a network problem, and saying so matters: it means this phone
            // and that Mac hold different keys, which no amount of retrying fixes.
            problem = failure == .couldNotOpen
                ? "Non riesco a decifrare: la chiave non corrisponde. Riaccoppia."
                : "Dati dal Mac illeggibili."
        } catch {
            problem = "Relay irraggiungibile."
        }
    }

    // MARK: - Comandi

    /// Requests whose answer is on its way, so a button cannot be pressed twice
    /// while the network thinks about it.
    @Published private(set) var inFlight: Set<String> = []

    func decide(_ session: ClaudeSessionStatus, allow: Bool, remember: Bool) async {
        guard let requestID = session.requestID else { return }
        guard let url = URL(string: relayURL + "/command"),
              let secret = RemoteSecrets.read(.pairSecret),
              let keyText = RemoteSecrets.read(.encryptionKey),
              let key = try? RemoteCrypto.importKey(keyText)
        else { return }

        let envelope = RemoteCommandEnvelope(
            command: .decide(requestID: requestID, allow: allow, remember: remember)
        )
        guard let sealed = try? RemoteCrypto.seal(envelope, with: key) else { return }

        inFlight.insert(session.id)
        defer { inFlight.remove(session.id) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // The envelope's own id travels in the clear so the Mac can address and
        // delete it. An opaque identifier says nothing about what was decided.
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["id": envelope.id, "payload": sealed]
        )
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                problem = "Il relay ha rifiutato la risposta (\(code))."
                return
            }
        } catch {
            problem = "Non sono riuscito a mandare la risposta."
            return
        }

        // Fetch straight away rather than waiting for the next tick: the Mac
        // collects within a couple of seconds, and the row should stop showing a
        // decision that has been made.
        try? await Task.sleep(for: .seconds(3))
        await refresh()
    }

    /// Polls while the app is on screen. Stopped when it is not: a phone that
    /// keeps asking from a pocket spends battery to learn things nobody reads.
    func startRefreshing(every seconds: Duration = .seconds(5)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: seconds)
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
