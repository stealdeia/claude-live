import Foundation
import Combine
import CryptoKit
import ClaudeLiveKit

/// Collects what the phone decided and carries it out.
///
/// Polls, and only while there is something to answer. A permission request
/// blocks its hook for a handful of seconds; outside that window nothing the
/// phone could say has anywhere to land, so asking would be spending requests to
/// hear silence. The polling window is exactly the window in which an answer
/// still means something.
@MainActor
final class RemoteCommandReceiver: ObservableObject {

    private let settings: Settings
    private let status: ClaudeStatusStore
    private var cancellables = Set<AnyCancellable>()
    private var loop: Task<Void, Never>?

    /// Commands already carried out. A delete can fail — the network is what it
    /// is — and a permission granted twice is a permission granted to something
    /// the user saw once.
    private var handled = Set<String>()

    /// Brisk, because a hook is waiting on the other side of it.
    private static let interval: Duration = .seconds(2)

    init(settings: Settings, status: ClaudeStatusStore) {
        self.settings = settings
        self.status = status

        // Anything that changes whether an answer is possible restarts the loop.
        Publishers.CombineLatest(settings.$remoteEnabled, status.$waitingSessions)
            .sink { [weak self] enabled, waiting in
                guard let self else { return }
                let answerable = enabled && waiting.contains(where: \.isDecidable)
                answerable ? self.start() : self.stop()
            }
            .store(in: &cancellables)
    }

    private func start() {
        guard loop == nil else { return }
        Log.debug("Ascolto i comandi dal telefono", category: .status)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.collect()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private func stop() {
        guard loop != nil else { return }
        loop?.cancel()
        loop = nil
        // Forgotten deliberately: the ids that matter have already been acted on,
        // and keeping them forever would grow without bound for no benefit.
        handled.removeAll()
    }

    // MARK: - Raccolta

    private func collect() async {
        guard let base = RemotePublisher.normalised(settings.remoteRelayURL),
              let url = URL(string: base + "/commands"),
              let pairID = RemoteSecrets.pairID(),
              let key = RemoteSecrets.encryptionKey()
        else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(pairID)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = body["commands"] as? [[String: Any]]
        else { return }

        for entry in entries {
            guard let id = entry["id"] as? String,
                  let payload = entry["payload"] as? String,
                  !handled.contains(id)
            else { continue }

            apply(payload: payload, id: id, key: key, base: base, pairID: pairID)
        }
    }

    private func apply(payload: String, id: String, key: SymmetricKey, base: String, pairID: String) {
        let envelope: RemoteCommandEnvelope
        do {
            envelope = try RemoteCrypto.open(RemoteCommandEnvelope.self, from: payload, with: key)
        } catch {
            // Cannot be opened: either not from our phone, or altered. Dropped
            // and marked handled, because retrying will not make it readable.
            Log.error("Comando dal telefono illeggibile, ignorato")
            handled.insert(id)
            forget(id: id, base: base, pairID: pairID)
            return
        }

        handled.insert(id)

        guard envelope.isFresh() else {
            // Issued while the phone was offline and delivered late. Obeying it
            // now would answer a question that has already been settled.
            Log.important("Comando scaduto, ignorato", category: .status)
            forget(id: id, base: base, pairID: pairID)
            return
        }

        switch envelope.command {
        case .decide(let requestID, let allow, let remember):
            // Matched against what is actually pending: the phone may be showing
            // a request the hook has already timed out of.
            guard let session = status.waitingSessions.first(where: { $0.requestID == requestID }) else {
                // The case behind "I pressed Allow and nothing happened": worth
                // a trace even with debug logging off.
                Log.important("Il permesso «\(requestID)» non è più in attesa", category: .status)
                forget(id: id, base: base, pairID: pairID)
                return
            }
            Log.important(
                "Dal telefono: \(allow ? "consentito" : "negato")\(remember ? " per sempre" : "") in \(session.projectName)",
                category: .status
            )
            status.decide(session, allow: allow, remember: remember)

        case .prompt:
            // No supported way to inject input into a live session exists yet.
            Log.info("Comando «prompt» ricevuto ma non ancora supportato", category: .status)
        }

        forget(id: id, base: base, pairID: pairID)
    }

    /// Tells the relay to drop it. Best effort: `handled` is what actually
    /// prevents a repeat, this only keeps the list from filling up.
    private func forget(id: String, base: String, pairID: String) {
        guard let url = URL(string: base + "/commands?id=" + id) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(pairID)", forHTTPHeaderField: "authorization")
        Task { _ = try? await URLSession.shared.data(for: request) }
    }
}
