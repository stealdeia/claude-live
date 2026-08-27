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
        isPaired = RemoteSecrets.read(.pairID) != nil
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
              let pairID = fields["id"], pairID.count == 32,
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
        RemoteSecrets.write(pairID, to: .pairID)
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
              let pairID = RemoteSecrets.read(.pairID)
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairID)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Which APNs world this token belongs to. A build on the cable registers
        // with the sandbox, one from TestFlight with production, and a token from
        // one is refused by the other — so the phone says which, instead of
        // leaving the relay to guess for every build at once.
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["deviceToken": hex, "environment": environment]
        )
        request.timeoutInterval = 15

        // Re-sent on every launch, not only at pairing: iOS may hand out a new
        // token after a reinstall or a restore, and a stale one on the relay
        // fails silently — APNs accepts the request and delivers to nobody.
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Dice al relay quali avvisi questo telefono vuole ricevere.
    ///
    /// Restituisce il motivo del fallimento, o `nil` se è andata: chi chiama
    /// decide se vale la pena dirlo, e qui non c'è modo di saperlo.
    ///
    /// Non passa dal Mac di proposito. Il Mac interroga il relay solo mentre c'è
    /// una risposta possibile, quindi una preferenza spedita a lui potrebbe
    /// restare non letta per ore — e nel frattempo le notifiche continuerebbero
    /// ad arrivare, che è esattamente il guasto che questo evita.
    func sendNotificationPreferences(_ prefs: [String: Bool]) async -> String? {
        guard isPaired else { return nil }
        guard let url = URL(string: relayURL + "/prefs"),
              let pairID = RemoteSecrets.read(.pairID)
        else { return "Nessun Mac accoppiato." }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairID)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: prefs)
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                return "Il relay ha risposto \(code): le notifiche potrebbero non seguire questa scelta."
            }
            return nil
        } catch {
            return "Scelta non arrivata al relay: riprovo alla prossima apertura."
        }
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
              let pairID = RemoteSecrets.read(.pairID),
              let keyText = RemoteSecrets.read(.encryptionKey),
              let key = try? RemoteCrypto.importKey(keyText)
        else {
            problem = "Accoppiamento incompleto."
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(pairID)", forHTTPHeaderField: "authorization")
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

            let fresh = try RemoteCrypto.open(RemoteSnapshot.self, from: payload, with: key)

            // Forget an answer the moment the Mac stops describing the request
            // it belongs to: keeping it would silence the session's next
            // question, which is a worse failure than showing one twice.
            var stillOpen: [String: String] = [:]
            for session in fresh.sessions {
                if let requestID = session.requestID { stillOpen[session.id] = requestID }
            }
            answeredRequests = answeredRequests.filter { stillOpen[$0.key] == $0.value }

            recomputeInFlight()

            snapshot = fresh
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

    /// Answers still travelling to the relay.
    private var sending: Set<String> = []

    /// Answers the relay has taken but the Mac has not collected yet, by session.
    ///
    /// Outliving the round trip on purpose: the Mac collects every two seconds
    /// and only then publishes again, so in between its snapshot still calls the
    /// request open. Without this, that snapshot puts the buttons back on screen
    /// for a question already decided — seen happening on 2026-08-20.
    ///
    /// Deliberately *not* done by marking the request unanswerable: in the model
    /// a request the app cannot answer is one the terminal must answer, so that
    /// route told the user to walk to the Mac for something already decided.
    ///
    /// Dropped as soon as the Mac's snapshot moves on, so the next question in
    /// the same session is never hidden by the answer to the previous one.
    private var answeredRequests: [String: String] = [:]

    /// Anything answered — still in the air, or merely not yet reflected by the
    /// Mac — shows as travelling rather than as a question.
    private func recomputeInFlight() {
        inFlight = sending.union(answeredRequests.keys)
    }

    func decide(_ session: ClaudeSessionStatus, allow: Bool, remember: Bool) async {
        guard let requestID = session.requestID else { return }
        guard let url = URL(string: relayURL + "/command"),
              let pairID = RemoteSecrets.read(.pairID),
              let keyText = RemoteSecrets.read(.encryptionKey),
              let key = try? RemoteCrypto.importKey(keyText)
        else { return }

        let envelope = RemoteCommandEnvelope(
            command: .decide(requestID: requestID, allow: allow, remember: remember)
        )
        guard let sealed = try? RemoteCrypto.seal(envelope, with: key) else { return }

        sending.insert(session.id)
        recomputeInFlight()
        // Cleared even on the failure paths below: an answer that never landed
        // has to be offered again, or the request is stranded.
        defer {
            sending.remove(session.id)
            recomputeInFlight()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairID)", forHTTPHeaderField: "authorization")
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

        // Recorded only now: an answer the relay refused is not an answer, and
        // suppressing the card for it would strand the request with no way left
        // to decide it.
        answeredRequests[session.id] = requestID
        recomputeInFlight()

        // No pause before refreshing any more. Waiting three seconds was a guess
        // at how long the Mac takes to collect and republish, and the guess was
        // wrong often enough to be the bug. The answer is remembered here now, so
        // the snapshot can arrive whenever it likes and still not reopen it.
        await refresh()
    }

    /// Risponde a una domanda a scelta multipla che l'hook sta trattenendo.
    ///
    /// Il gemello di `decide`, e separato per la stessa ragione per cui i due
    /// pulsanti non sono lo stesso pulsante: là si concede o si nega, qui si
    /// scrive una risposta. Prima che esistesse, una domanda arrivata al telefono
    /// si poteva solo «consentire» — cosa che liberava la chiamata senza
    /// rispondere niente e mandava la domanda nel terminale, dove nessuno era.
    func answer(_ session: ClaudeSessionStatus, answers: [String: String]) async {
        guard let requestID = session.requestID else { return }
        let filled = answers.filter { !$0.value.isEmpty }
        guard !filled.isEmpty else { return }

        guard let url = URL(string: relayURL + "/command"),
              let pairID = RemoteSecrets.read(.pairID),
              let keyText = RemoteSecrets.read(.encryptionKey),
              let key = try? RemoteCrypto.importKey(keyText)
        else { return }

        let envelope = RemoteCommandEnvelope(
            command: .answer(requestID: requestID, answers: filled)
        )
        guard let sealed = try? RemoteCrypto.seal(envelope, with: key) else { return }

        sending.insert(session.id)
        recomputeInFlight()
        defer {
            sending.remove(session.id)
            recomputeInFlight()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairID)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
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

        answeredRequests[session.id] = requestID
        recomputeInFlight()
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
