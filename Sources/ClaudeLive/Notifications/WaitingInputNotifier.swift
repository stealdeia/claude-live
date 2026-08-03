import Foundation
import UserNotifications

/// Notifies when Claude Code starts waiting for the user in some project.
///
/// This is the notification that actually earns its keep: a permission prompt in
/// a background VS Code window is easy to miss for minutes.
@MainActor
final class WaitingInputNotifier {
    /// Suppresses repeats for the same project within this window, so a session
    /// that flips in and out of waiting doesn't produce a stream of banners.
    private let cooldown: TimeInterval = 60

    private var lastNotified: [String: Date] = [:]

    /// `projectPath` travels in `userInfo` so tapping the notification can bring
    /// that project forward — the previous version could only activate the app,
    /// which for a menu-bar app meant nothing happened.
    func notifyWaiting(projectName: String, projectPath: String, badge: String?, summary: String?) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let now = Date()
        if let previous = lastNotified[projectName], now.timeIntervalSince(previous) < cooldown {
            return
        }
        lastNotified[projectName] = now

        let content = UNMutableNotificationContent()
        content.title = "Claude ti aspetta in \(projectName)"
        // The command itself is more useful than the word "permission".
        if let summary, !summary.isEmpty {
            content.subtitle = badge.map { "Richiesta: \($0)" } ?? "Richiesta"
            content.body = summary
        } else {
            content.body = badge.map { "Richiesta: \($0)" } ?? "Claude Code attende una risposta."
        }
        content.sound = .default
        content.userInfo = ["projectPath": projectPath, "projectName": projectName]

        let request = UNNotificationRequest(
            identifier: "waiting-\(projectName)-\(Int(now.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.error("Notifica «attende input» fallita: \(error.localizedDescription)", category: .status)
            }
        }
        Log.info("Notifica: Claude attende input in \(projectName)", category: .status)
    }
}
