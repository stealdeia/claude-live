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

    func notifyWaiting(projectName: String, badge: String?) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let now = Date()
        if let previous = lastNotified[projectName], now.timeIntervalSince(previous) < cooldown {
            return
        }
        lastNotified[projectName] = now

        let content = UNMutableNotificationContent()
        content.title = "Claude ti aspetta in \(projectName)"
        content.body = badge.map { "Richiesta: \($0)" } ?? "Claude Code attende una risposta."
        content.sound = .default

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
