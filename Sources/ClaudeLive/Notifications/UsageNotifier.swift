import Foundation
import UserNotifications
import ClaudeLiveKit

/// Fires at most one notification per (window, threshold, reset period), so a
/// five-minute poll can't turn into a five-minute nag — e la memoria di ciò che è
/// già stato annunciato sta su disco, perché altrimenti a sopravvivere al riavvio
/// dell'app è soltanto la notifica ripetuta.
@MainActor
final class UsageNotifier {
    private enum Tier: String {
        case warning, danger
    }

    private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
        firedKeys = Self.loadFired()
    }

    private var authorized = false
    private var authorizationRequested = false
    private var firedKeys: Set<String> = []

    /// Le soglie già annunciate, su disco.
    ///
    /// In memoria non bastava: a ogni riavvio dell'app tutte le soglie si
    /// riarmavano, e la stessa notifica arrivava una seconda volta. Osservato il
    /// 2026-08-21 — 76% alle 13:05, riavvio alle 13:08:22, 77% alle 13:08:23 — e
    /// due volte il 17 agosto, senza che nessuno collegasse le due cose.
    ///
    /// Non è un caso di laboratorio: l'app si riavvia a ogni aggiornamento, e gli
    /// aggiornamenti li installa Sparkle da sé.
    private static var firedFile: URL {
        Paths.supportDirectory.appendingPathComponent("usage-notified.json")
    }

    /// Si potano le chiavi la cui finestra si è già azzerata.
    ///
    /// La chiave porta dentro l'orario di reset — `5h-1787310600-warning` — quindi
    /// la scadenza è leggibile dalla chiave stessa e non serve conservare altro.
    /// Passata quella, la soglia va riarmata: è una finestra nuova.
    ///
    /// Le chiavi senza orario di reset non vengono salvate affatto: non si
    /// saprebbe quando buttarle, e resterebbero a zittire per sempre una soglia.
    private static func loadFired() -> Set<String> {
        guard let data = try? Data(contentsOf: firedFile),
              let keys = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        let now = Date().timeIntervalSince1970
        let live = Set(keys.filter { key in
            let parts = key.split(separator: "-")
            guard parts.count == 3, let period = Double(parts[1]) else { return false }
            return period > now
        })
        if !keys.isEmpty {
            Log.debug(
                "Soglie già annunciate: \(live.count) valide, \(keys.count - live.count) scadute",
                category: .usage
            )
        }
        return live
    }

    private func saveFired() {
        let keepable = firedKeys.filter { $0.split(separator: "-").count == 3 && Double($0.split(separator: "-")[1]) != nil }
        guard let data = try? JSONSerialization.data(withJSONObject: Array(keepable)) else { return }
        try? FileManager.default.createDirectory(
            at: Paths.supportDirectory, withIntermediateDirectories: true
        )
        try? data.write(to: Self.firedFile, options: .atomic)
    }

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

    /// One notification per incident: fired when the data stops updating for a
    /// reason that needs the user (token refused, credentials unreadable),
    /// re-armed by `clearProblem` once data flows again. Without the latch a
    /// five-minute poll against a dead token would nag every five minutes.
    private var problemNotified = false

    func notifyProblem(_ body: String) {
        guard !problemNotified else { return }
        problemNotified = true
        post(title: "Claude Live non si aggiorna", body: body)
    }

    func clearProblem() {
        problemNotified = false
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
        saveFired()

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
        content.sound = NotificationSound.sound(named: settings.notificationSound)

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
