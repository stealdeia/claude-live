import Foundation
import UserNotifications
import ClaudeLiveKit

/// Posts a macOS notification for what happened in a project.
///
/// One notifier for all three kinds rather than one per kind, because the thing
/// that must not be duplicated is the **cooldown**: a session that flips in and out
/// of a state would otherwise produce a stream of banners, and the rule is per
/// project *and* per kind — finishing a turn must not silence a permission request
/// arriving a moment later.
@MainActor
final class ClaudeAlertNotifier {
    /// Suppresses repeats of the same kind in the same project within this window.
    private let cooldown: TimeInterval = 60

    private var lastNotified: [String: Date] = [:]

    private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
    }

    /// Whether the user wants a banner for this kind at all.
    func isEnabled(_ kind: ClaudeAlertKind) -> Bool {
        switch kind {
        case .waiting: return settings.notifyOnWaitingInput
        case .done: return settings.notifyOnDone
        case .failed: return settings.notifyOnFailure
        }
    }

    /// `projectPath` travels in `userInfo` so tapping the notification can bring
    /// that project forward — activating the app would do nothing visible for a
    /// menu-bar app.
    func notify(_ alert: ClaudeAlert, badge: String?, summary: String?) {
        guard Bundle.main.bundleIdentifier != nil, isEnabled(alert.kind) else { return }

        let key = "\(alert.kind.rawValue)#\(alert.projectPath)"
        let now = Date()
        if let previous = lastNotified[key], now.timeIntervalSince(previous) < cooldown {
            return
        }
        lastNotified[key] = now

        let content = UNMutableNotificationContent()
        content.title = alert.kind.notificationTitle(project: alert.projectName)

        // The command itself is more useful than the word "permission"; for the
        // other kinds the detail is the tool or the error.
        if let summary, !summary.isEmpty {
            content.subtitle = badge.map { "Richiesta: \($0)" } ?? "Richiesta"
            content.body = summary
        } else if let body = self.body(for: alert, badge: badge) {
            content.body = body
        }

        content.sound = NotificationSound.sound(named: settings.notificationSound)
        content.userInfo = ["projectPath": alert.projectPath, "projectName": alert.projectName]

        let request = UNNotificationRequest(
            identifier: Self.identifier(kind: alert.kind, projectPath: alert.projectPath),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.error("Notifica «\(alert.kind.rawValue)» fallita: \(error.localizedDescription)", category: .status)
            }
        }
        Log.info("Notifica: \(alert.kind.label) in \(alert.projectName)", category: .status)
    }

    /// Names the banner for one kind in one project.
    ///
    /// Stable on purpose. It used to carry the timestamp, which made every banner
    /// a new one: they stacked in Notification Center instead of replacing each
    /// other, and none could be taken down later because nothing knew its name.
    private static func identifier(kind: ClaudeAlertKind, projectPath: String) -> String {
        "alert|\(kind.rawValue)|\(projectPath)"
    }

    /// Takes down a project's banners, for when its alert is cleared.
    ///
    /// Without this a permission request answered in the panel left its banner
    /// sitting in Notification Center, still asking, for the rest of the day —
    /// reported on 2026-08-20. The banner is a statement about now; when now
    /// changes it has to go.
    func withdraw(forPath path: String) {
        let identifiers = ClaudeAlertKind.allCases.map {
            Self.identifier(kind: $0, projectPath: path)
        }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func body(for alert: ClaudeAlert, badge: String?) -> String? {
        switch alert.kind {
        case .waiting:
            return badge.map { "Richiesta: \($0)" } ?? "Claude Code attende una risposta."
        case .done:
            return "Il turno è finito: nessuna operazione in corso."
        case .failed:
            return alert.detail.map { "Interrotto: \($0)" }
                ?? "Il turno si è interrotto senza completare."
        }
    }
}
