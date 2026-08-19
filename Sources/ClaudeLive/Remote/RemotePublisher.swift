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
                if enabled { self.publishSoon(immediate: true) } else { self.connection = .off }
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
              let secret = RemoteSecrets.read(.pairSecret),
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
        if let notify = notificationText() { body["notify"] = notify }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
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
        let base = settings.remoteRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let url = URL(string: base + path), url.scheme == "https" else {
            return nil
        }
        return url
    }

    // MARK: - Accoppiamento

    /// What the phone reads off the screen: address, password and key together,
    /// so pairing is one act rather than three fields typed by hand.
    ///
    /// The key travels by QR and never through the relay — which is what makes
    /// the relay unable to read anything it carries.
    func pairingPayload() -> String? {
        guard let secret = RemoteSecrets.read(.pairSecret),
              let key = RemoteSecrets.encryptionKey()
        else { return nil }

        let payload: [String: String] = [
            "v": "1",
            "url": settings.remoteRelayURL.trimmingCharacters(in: .whitespacesAndNewlines),
            "secret": secret,
            "key": RemoteCrypto.export(key),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func publishNow() { publishSoon(immediate: true) }
}
