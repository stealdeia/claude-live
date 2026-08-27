import Foundation
import Combine
import CryptoKit
import ClaudeLiveKit

/// Sends what the Mac knows to the relay, so the phone can read it.
///
/// The one place in this app where data leaves the machine, which is why the
/// switch that turns it on defaults to off and why everything is sealed before
/// it goes. Nothing here decides *what* is worth knowing: it observes the same
/// stores the panel draws from, so the phone and the panel can never disagree.
@MainActor
final class RemotePublisher: ObservableObject {

    enum Connection: Equatable {
        case off
        case notConfigured
        case publishing
        case failed(String)

        var label: String {
            switch self {
            case .off: return "Spento"
            case .notConfigured: return "Da configurare"
            case .publishing: return "Attivo"
            case .failed(let message): return message
            }
        }
    }

    @Published private(set) var connection: Connection = .off
    @Published private(set) var lastPublishedAt: Date?

    private let settings: Settings
    private let status: ClaudeStatusStore
    private let usage: UsageMonitor
    private var cancellables = Set<AnyCancellable>()

    /// Coalesces bursts. A tool call can change the status file several times a
    /// second, and the phone gains nothing from seeing each one — but an alert
    /// bypasses this, because being late with "Claude is waiting" defeats the
    /// point of the app.
    private var pending: Task<Void, Never>?
    private static let debounce: Duration = .seconds(2)

    /// Publishes even when nothing changed, because silence is ambiguous.
    ///
    /// A Mac that is simply quiet — Claude thinking for a few minutes, nothing
    /// else moving — looked exactly like one that had gone away: publishing only
    /// on change meant the snapshot aged, and the app warns as soon as it is over
    /// two minutes old. Which reads as "the Mac is disconnected", and sends you to
    /// check on it — the very trip this is meant to spare you. Observed doing
    /// precisely that on 2026-08-19.
    ///
    /// Sixty seconds, chosen against the app's two-minute warning rather than
    /// against the relay's ten-minute expiry: a heartbeat that only beat inside
    /// the expiry would still let the warning appear before every beat, which is
    /// the symptom, not the storage.
    private var heartbeat: Task<Void, Never>?
    private static let heartbeatInterval: Duration = .seconds(60)

    /// The alert already announced, so a snapshot published for another reason
    /// does not push the same notification twice.
    private var announcedAlert: ClaudeAlert?

    init(settings: Settings, status: ClaudeStatusStore, usage: UsageMonitor) {
        self.settings = settings
        self.status = status
        self.usage = usage

        settings.$remoteEnabled
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.publishSoon(immediate: true)
                    self.startHeartbeat()
                } else {
                    self.connection = .off
                    self.stopHeartbeat()
                }
            }
            .store(in: &cancellables)

        // Everything the panel reacts to, the phone reacts to as well.
        Publishers.MergeMany(
            status.$statusesByPath.map { _ in () }.eraseToAnyPublisher(),
            status.$sessionsByPath.map { _ in () }.eraseToAnyPublisher(),
            usage.$snapshot.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in self?.publishSoon() }
        .store(in: &cancellables)

        // Alerts jump the queue.
        status.$alerts
            .sink { [weak self] _ in self?.publishSoon(immediate: true) }
            .store(in: &cancellables)
    }

    // MARK: - Programmazione

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                if Task.isCancelled { return }
                await self?.publish()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    private func publishSoon(immediate: Bool = false) {
        guard settings.remoteEnabled else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: Self.debounce)
                if Task.isCancelled { return }
            }
            await self?.publish()
        }
    }

    // MARK: - Invio

    private func publish() async {
        guard settings.remoteEnabled else { return }

        guard let url = relayURL(path: "/publish"),
              let pairID = RemoteSecrets.pairID(),
              let key = RemoteSecrets.encryptionKey()
        else {
            connection = .notConfigured
            return
        }

        let snapshot = makeSnapshot()

        let sealed: String
        do {
            sealed = try RemoteCrypto.seal(snapshot, with: key)
        } catch {
            connection = .failed("Cifratura fallita")
            Log.error("Cifratura dello snapshot fallita: \(error.localizedDescription)")
            return
        }

        var body: [String: Any] = ["payload": sealed]
        if let notify = notificationText() {
            body["notify"] = notify
            // Il tipo viaggia accanto al testo perché è il relay a decidere se
            // spingere: il telefono può spegnere una categoria, e il Mac non lo
            // saprebbe mai in tempo — lo interroga solo mentre c'è qualcosa da
            // rispondere. Il testo resta generico, il tipo è una parola sola:
            // nessuno dei due nomina un progetto.
            if let kind = status.topAlert?.kind { body["notifyKind"] = kind.rawValue }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairID)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                connection = .publishing
                lastPublishedAt = Date()
                announcedAlert = status.topAlert
            } else {
                connection = .failed("Il relay ha risposto \(code)")
            }
        } catch {
            // Being offline is normal and not worth shouting about; the state
            // says so and the next change will try again.
            connection = .failed("Relay irraggiungibile")
            Log.debug("Pubblicazione fallita: \(error.localizedDescription)", category: .status)
        }
    }

    private func makeSnapshot() -> RemoteSnapshot {
        RemoteSnapshot(
            usage: usage.snapshot,
            projects: Array(status.statusesByPath.values).sorted { $0.state > $1.state },
            sessions: status.sessionsByPath.values.flatMap { $0 },
            alert: status.topAlert,
            generatedAt: Date()
        )
    }

    /// Generic on purpose: this text is read by Apple and by the relay, so
    /// naming the project here would undo the encryption for the one field a
    /// passer-by would find most interesting. The app fills in the detail once
    /// it has opened the snapshot.
    private func notificationText() -> String? {
        guard let alert = status.topAlert, alert != announcedAlert else { return nil }
        switch alert.kind {
        case .waiting: return "Claude aspetta una risposta"
        case .done: return "Claude ha finito"
        case .failed: return "Claude si è interrotto"
        }
    }

    private func relayURL(path: String) -> URL? {
        guard let base = Self.normalised(settings.remoteRelayURL) else { return nil }
        return URL(string: base + path)
    }

    /// Accepts what a person actually types.
    ///
    /// Rejecting `claude-live-relay.example.workers.dev` for want of a `https://`
    /// is technically correct and useless: the state goes to "not configured"
    /// and nothing says why. Nobody means `http`, and nobody means a trailing
    /// slash, so both are handled rather than refused.
    ///
    /// Returns nil only when there is genuinely nothing usable.
    static func normalised(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("http://") {
            text = "https://" + text.dropFirst("http://".count)
        } else if !text.hasPrefix("https://") {
            text = "https://" + text
        }

        while text.hasSuffix("/") { text.removeLast() }

        guard let url = URL(string: text), url.scheme == "https", url.host?.isEmpty == false else {
            return nil
        }
        return text
    }

    // MARK: - Accoppiamento

    /// What the phone reads off the screen: address, password and key together,
    /// so pairing is one act rather than three fields typed by hand.
    ///
    /// The key travels by QR and never through the relay — which is what makes
    /// the relay unable to read anything it carries.
    func pairingPayload() -> String? {
        guard let pairID = RemoteSecrets.pairID(),
              let key = RemoteSecrets.encryptionKey()
        else { return nil }

        let payload: [String: String] = [
            // Version 2 carries an identifier where version 1 carried a password
            // typed in by hand. An app meant to be installed by people who did
            // not build it cannot ask for that password, and a password shipped
            // with the app protects nobody.
            "v": "2",
            "url": settings.remoteRelayURL.trimmingCharacters(in: .whitespacesAndNewlines),
            "id": pairID,
            "key": RemoteCrypto.export(key),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func publishNow() { publishSoon(immediate: true) }
}
