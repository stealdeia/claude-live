import Foundation
import UserNotifications

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
            identifier: "\(alert.kind.rawValue)-\(alert.projectName)-\(Int(now.timeIntervalSince1970))",
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
