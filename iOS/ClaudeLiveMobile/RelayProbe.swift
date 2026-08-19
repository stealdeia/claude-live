import Foundation
import UserNotifications
import UIKit

/// The phase 0 measurement, and nothing else.
///
/// It registers with APNs, hands the resulting token to the relay, and records
/// how long a push took to arrive. That number decides whether answering a
/// permission request from the phone is possible at all, so the app that
/// produces it stays small enough to be obviously correct.
///
/// The relay address and shared secret are typed in and kept in `UserDefaults`,
/// never compiled in: this repository is public, and a secret in source is a
/// secret published.
@MainActor
final class RelayProbe: NSObject, ObservableObject {
    @Published var relayURL: String {
        didSet { defaults.set(relayURL, forKey: Keys.relayURL) }
    }
    @Published var secret: String {
        didSet { defaults.set(secret, forKey: Keys.secret) }
    }

    @Published private(set) var deviceToken: String?
    @Published private(set) var status: String = "Non registrato"
    /// Most recent first: a single reading says little, a handful shows spread.
    @Published private(set) var measurements: [Measurement] = []

    struct Measurement: Identifiable {
        let id = UUID()
        let milliseconds: Int
        let arrival: Arrival
        let at: Date

        /// Whether the number is transport time or transport plus a human.
        enum Arrival {
            /// App was open: the timestamp is when iOS handed us the push.
            case foreground
            /// App was closed: the timestamp is when the notification was
            /// tapped, so it includes noticing and reaching for the phone.
            case tapped
        }
    }

    private enum Keys {
        static let relayURL = "relayURL"
        static let secret = "secret"
    }

    private let defaults = UserDefaults.standard

    override init() {
        relayURL = defaults.string(forKey: Keys.relayURL) ?? ""
        secret = defaults.string(forKey: Keys.secret) ?? ""
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Registrazione

    func requestPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                status = "Permesso notifiche negato"
                return
            }
            status = "Permesso concesso, chiedo il token…"
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            status = "Errore permesso: \(error.localizedDescription)"
        }
    }

    func didRegister(tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        status = "Token ottenuto, lo consegno al relay…"
        Task { await sendToken(token) }
    }

    func didFailToRegister(error: Error) {
        status = "APNs ha rifiutato la registrazione: \(error.localizedDescription)"
    }

    private func sendToken(_ token: String) async {
        guard let request = makeRequest(path: "/register", body: ["deviceToken": token]) else {
            status = "Indirizzo del relay non valido"
            return
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            status = code == 200
                ? "Registrato. Lancia /ping dal Mac."
                : "Il relay ha risposto \(code)"
        } catch {
            status = "Relay irraggiungibile: \(error.localizedDescription)"
        }
    }

    // MARK: - Misura

    /// `sentAt` is stamped by the relay and travels inside the push, so the
    /// subtraction happens here — the one place that knows when it arrived.
    ///
    /// Takes the timestamp rather than the payload on purpose: the notification
    /// dictionary is `[AnyHashable: Any]` and cannot cross an isolation boundary,
    /// so the one value we need is lifted out on the other side.
    private func record(sentAt: Double, arrival: Measurement.Arrival) {
        let receivedAt = Date().timeIntervalSince1970 * 1000
        let elapsed = Int(receivedAt - sentAt)

        measurements.insert(
            Measurement(milliseconds: elapsed, arrival: arrival, at: Date()),
            at: 0
        )
        status = "Arrivata in \(elapsed) ms"

        Task { await acknowledge(sentAt: sentAt, receivedAt: receivedAt) }
    }

    private func acknowledge(sentAt: Double, receivedAt: Double) async {
        guard let request = makeRequest(
            path: "/ack",
            body: ["sentAt": sentAt, "receivedAt": receivedAt]
        ) else { return }
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Rete

    private func makeRequest(path: String, body: [String: Any]) -> URLRequest? {
        let trimmed = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed + path), url.scheme == "https" else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}

extension RelayProbe: UNUserNotificationCenterDelegate {
    /// Arrival while the app is open. This is the clean transport measurement:
    /// no human sits between the push and the timestamp.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if let sentAt = notification.request.content.userInfo["sentAt"] as? Double {
            await record(sentAt: sentAt, arrival: .foreground)
        }
        // Returning the sound and banner explicitly is what stops iOS from
        // silently dropping a notification that arrives while the app is open —
        // the same trap the Mac app documents for `willPresent`.
        return [.banner, .sound, .list]
    }

    /// The notification was tapped. Honest about what it measures: the transport
    /// plus however long the phone sat unnoticed in a pocket.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if let sentAt = response.notification.request.content.userInfo["sentAt"] as? Double {
            await record(sentAt: sentAt, arrival: .tapped)
        }
    }
}
