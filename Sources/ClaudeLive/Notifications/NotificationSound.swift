import AppKit
import UserNotifications

/// Which sound Claude Live's notifications play.
///
/// macOS keeps its alert sounds as `.aiff` files in `/System/Library/Sounds`, and
/// the notification server resolves a `UNNotificationSound` name against the same
/// search path `NSSound(named:)` uses — so storing the bare file name is enough,
/// and nothing has to be copied into the bundle.
///
/// The list is read from disk rather than hard-coded: it has changed across macOS
/// releases, and a name we no longer find is treated as "use the default" instead
/// of producing a silent notification.
enum NotificationSound {
    /// Stored value meaning "whatever macOS considers the default alert sound".
    static let systemDefault = ""

    private static let directory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)

    /// Names available on this Mac, without the extension, alphabetically.
    ///
    /// Read once: the folder belongs to the system volume and cannot change while
    /// the app runs.
    static let available: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "aiff" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }()

    static func label(for name: String) -> String {
        name.isEmpty ? "Predefinito di macOS" : name
    }

    /// A stored name is only honoured if the file is still there.
    static func isKnown(_ name: String) -> Bool {
        name.isEmpty || available.contains(name)
    }

    static func sound(named name: String) -> UNNotificationSound {
        guard !name.isEmpty, available.contains(name) else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName("\(name).aiff"))
    }

    /// Posts a real notification with the chosen sound.
    ///
    /// Deliberately not `NSSound.play()`: what matters is what the *notification*
    /// will sound like, and only the notification path exercises the same lookup
    /// macOS does at delivery time. Previewing with `NSSound` would hide a name
    /// the notification server cannot resolve.
    ///
    /// Authorization is (re)requested first: it is granted at launch only if some
    /// notification was already enabled, and a preview button that silently does
    /// nothing is worse than one that says why. When permission is already there
    /// this returns immediately and prompts no one.
    static func preview(_ name: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                Log.error("Prova suono: notifiche non autorizzate (\(error?.localizedDescription ?? "negate"))")
                Task { @MainActor in reportNotAuthorized() }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Suono di prova"
            content.body = "Claude Live userà «\(label(for: name))» per avvisarti."
            content.sound = sound(named: name)

            let request = UNNotificationRequest(
                identifier: "sound-preview",
                content: content,
                trigger: nil
            )
            // Same identifier every time, removed first: repeated taps on «Prova»
            // must not stack up banners.
            center.removeDeliveredNotifications(withIdentifiers: ["sound-preview"])
            center.add(request) { error in
                if let error {
                    Log.error("Prova suono notifica fallita: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Logs what the notification centre actually did with the last preview.
    ///
    /// Exists because this path has already failed **silently**: a notification
    /// posted while the app is frontmost is dropped without an error unless the
    /// delegate presents it, so «nothing happened» was indistinguishable from
    /// «not authorised» and from «no such sound». Asking the centre what it holds
    /// is the only answer that is not a guess. Driven by
    /// `CLAUDELIVE_TEST_NOTIFICATION=1`.
    static func logDeliveryDiagnostics() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let delivered = await center.deliveredNotifications()
        let preview = delivered.first { $0.request.identifier == "sound-preview" }

        Log.info(
            "[notifiche] autorizzazione=\(settings.authorizationStatus.rawValue) "
            + "avvisi=\(settings.alertSetting.rawValue) suono=\(settings.soundSetting.rawValue) "
            + "consegnate=\(delivered.count) "
            + "prova=\(preview == nil ? "assente" : "presente")"
        )
    }

    @MainActor
    private static func reportNotAuthorized() {
        let alert = NSAlert()
        alert.messageText = "Notifiche non autorizzate"
        alert.informativeText = """
        macOS non permette a Claude Live di mostrare notifiche, quindi non c'è \
        niente da sentire. Attivale in Impostazioni di Sistema → Notifiche → \
        Claude Live.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Apri Impostazioni di Sistema")
        alert.addButton(withTitle: "Chiudi")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
