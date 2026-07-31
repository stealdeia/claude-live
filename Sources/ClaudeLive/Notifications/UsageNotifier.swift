import Foundation
import UserNotifications

/// Fires at most one notification per (window, threshold, reset period), so a
/// five-minute poll can't turn into a five-minute nag.
@MainActor
final class UsageNotifier {
    private enum Tier: String {
        case warning, danger
    }

    private var authorized = false
    private var authorizationRequested = false
    private var firedKeys: Set<String> = []

    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true

        // UNUserNotificationCenter requires a real bundle identifier; a bare
        // executable would trap, so bail out instead of crashing.
        guard Bundle.main.bundleIdentifier != nil else {
            Log.error("Notifiche non disponibili: eseguibile senza bundle identifier")
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                self.authorized = granted
                if let error {
                    Log.error("Autorizzazione notifiche fallita: \(error.localizedDescription)")
                } else {
                    Log.info("Notifiche \(granted ? "autorizzate" : "negate")")
                }
            }
        }
    }

    func evaluate(snapshot: UsageSnapshot, warn: Double, danger: Double) {
        check(window: snapshot.fiveHour, label: "sessione 5h", key: "5h", warn: warn, danger: danger)
        check(window: snapshot.sevenDay, label: "settimana 7d", key: "7d", warn: warn, danger: danger)
    }

    private func check(
        window: UsageWindow?,
        label: String,
        key: String,
        warn: Double,
        danger: Double
    ) {
        guard let window else { return }

        // Keying on the reset timestamp means the state auto-clears when a new
        // window begins — no manual bookkeeping needed.
        let period = window.resetAt.map { String(Int($0.timeIntervalSince1970)) } ?? "na"

        let tier: Tier?
        switch UsageLevel.level(for: window.utilization, warn: warn, danger: danger) {
        case .danger: tier = .danger
        case .warning: tier = .warning
        case .normal: tier = nil
        }
        guard let tier else { return }

        let firedKey = "\(key)-\(period)-\(tier.rawValue)"
        guard !firedKeys.contains(firedKey) else { return }
        firedKeys.insert(firedKey)

        // Reaching "danger" implies "warning" was passed; mark it so a later
        // dip back below the danger line doesn't re-fire the warning.
        if tier == .danger {
            firedKeys.insert("\(key)-\(period)-\(Tier.warning.rawValue)")
        }

        let title = tier == .danger
            ? "Limite \(label) quasi esaurito"
            : "Limite \(label) in avvicinamento"

        var body = "Utilizzo al \(Format.percent(window.utilization))."
        if let resetAt = window.resetAt {
            body += " Reset in \(Format.countdown(to: resetAt))."
        }

        post(title: title, body: body)
    }

    private func post(title: String, body: String) {
        guard authorized else {
            Log.debug("Notifica non inviata (non autorizzata): \(title) — \(body)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.error("Invio notifica fallito: \(error.localizedDescription)")
            }
        }
        Log.info("Notifica inviata: \(title)")
    }
}
