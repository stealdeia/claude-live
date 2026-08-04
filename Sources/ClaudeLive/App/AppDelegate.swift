import AppKit
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var settings: Settings!
    private var monitor: UsageMonitor!
    private var projects: ProjectsMonitor!
    private var status: ClaudeStatusStore!
    private var notifier: UsageNotifier!
    private var waitingNotifier: WaitingInputNotifier!
    private var menuBar: MenuBarController!
    private var panel: PanelController!
    private var notch: NotchController!
    private var updates: UpdateController!
    private var settingsWindow: SettingsWindowController!
    private var onboardingWindow: OnboardingWindowController!

    private var wakeObserver: Any?
    private var modeObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensureDirectories()
        Log.info("Claude Live avviata (bundle: \(Bundle.main.bundleIdentifier ?? "nessuno"))")

        settings = Settings.shared
        updates = UpdateController()
        notifier = UsageNotifier()
        waitingNotifier = WaitingInputNotifier()

        monitor = UsageMonitor(settings: settings, notifier: notifier)
        projects = ProjectsMonitor(settings: settings)
        status = ClaudeStatusStore(settings: settings, notifier: waitingNotifier)

        onboardingWindow = OnboardingWindowController(
            settings: settings,
            onInstallHooks: { [weak self] in self?.installHooks() }
        )

        settingsWindow = SettingsWindowController(
            settings: settings,
            monitor: monitor,
            status: status,
            updates: updates,
            onInstallHooks: { [weak self] in self?.installHooks() },
            onShowOnboarding: { [weak self] in self?.onboardingWindow.show() }
        )

        panel = PanelController(
            monitor: monitor,
            projects: projects,
            status: status,
            settings: settings,
            onOpenSettings: { [weak self] in self?.settingsWindow.show() },
            onInstallHooks: { [weak self] in self?.installHooks() },
            onQuit: { NSApp.terminate(nil) }
        )

        // The notch surface reuses the panel's action set: same commands, and
        // the SwiftUI section views are shared between both surfaces.
        notch = NotchController(
            monitor: monitor,
            projects: projects,
            status: status,
            settings: settings,
            actions: PanelActions(
                refreshNow: { [weak self] in
                    guard let self else { return }
                    Task { await self.monitor.refresh(reason: "notch") }
                    self.projects.refresh(reason: "notch")
                },
                toggleCollapsed: {},
                openSettings: { [weak self] in self?.settingsWindow.show() },
                installHooks: { [weak self] in self?.installHooks() },
                focusProject: { [weak self] path in self?.projects.focus(path: path) },
                quit: { NSApp.terminate(nil) }
            )
        )

        menuBar = MenuBarController(
            monitor: monitor,
            projects: projects,
            status: status,
            settings: settings,
            onTogglePanel: { [weak self] in self?.panel.toggleVisibility() },
            onOpenSettings: { [weak self] in self?.settingsWindow.show() },
            onOpenNotchScreens: { [weak self] in self?.settingsWindow.show(showingNotchScreens: true) },
            onInstallHooks: { [weak self] in self?.installHooks() },
            onCheckForUpdates: { [weak self] in self?.updates.checkForUpdates() },
            onShowOnboarding: { [weak self] in self?.onboardingWindow.show() }
        )

        // Set before any notification can be delivered, otherwise a tap on one
        // just activates the app — which for a menu-bar app looks like nothing
        // happened.
        UNUserNotificationCenter.current().delegate = self

        if settings.notificationsEnabled || settings.notifyOnWaitingInput {
            notifier.requestAuthorizationIfNeeded()
        }

        applyDisplayMode(isInitial: true)
        modeObserver = settings.$displayMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyDisplayMode() }
            }

        monitor.start()
        projects.start()
        status.start()

        // First launch: walk the user through requirements and permissions before
        // anything can silently fail.
        if !settings.hasCompletedOnboarding {
            onboardingWindow.show()
        }

        // Opt-in via CLAUDELIVE_SNAPSHOT=1: captures the notch surface shortly
        // after launch, collapsed and expanded, so its appearance can be checked
        // from a script — `screencapture` needs the Screen Recording permission,
        // drawing our own view needs nothing. Not tied to debug logging, because
        // it visibly opens and closes the panel.
        if ProcessInfo.processInfo.environment["CLAUDELIVE_SNAPSHOT"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.onboardingWindow.writeSnapshot(
                    to: Paths.supportDirectory.appendingPathComponent("onboarding.png")
                )
                self.settingsWindow.writeSnapshot(
                    to: Paths.supportDirectory.appendingPathComponent("settings.png")
                )
                self.settingsWindow.writeNotchScreensSnapshot(
                    to: Paths.supportDirectory.appendingPathComponent("notch-screens.png")
                )
                guard self.settings.displayMode == .notch else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.notch.writeSnapshot(to: Paths.supportDirectory.appendingPathComponent("notch-collapsed.png"))
                self.notch.setExpanded(true)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self.notch.writeSnapshot(to: Paths.supportDirectory.appendingPathComponent("notch-expanded.png"))
                self.notch.setExpanded(false)
            }
        }

        // Opt-in via CLAUDELIVE_SELFTEST=1: switches surfaces and reports what
        // ended up on screen. Exists because "switch to the notch and back" has
        // already shipped once leaving no visible surface at all — a failure the
        // code reads as correct and only use reveals.
        if ProcessInfo.processInfo.environment["CLAUDELIVE_SELFTEST"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.runSurfaceSelfTest()
            }
        }

        // Diagnostics: force an update check without UI, to verify the release
        // pipeline end to end from a script.
        if ProcessInfo.processInfo.environment["CLAUDELIVE_CHECK_UPDATES"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.updates.checkSilently()
            }
        }

        // Numbers go stale across sleep; refresh as soon as the Mac wakes.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Dark wake fires this too, hence `isAutomatic`: the keychain cannot
            // show its dialog with the screen off, and nobody is looking anyway.
            Task { @MainActor in await self?.monitor.refresh(reason: "risveglio", isAutomatic: true) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        projects?.stop()
        status?.stop()
        settings?.persistNow()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        Log.info("Claude Live terminata")
    }

    /// Menu-bar-only app: never quit just because no window is open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Notifications

    /// Tapping a "Claude is waiting" notification opens the project it refers to,
    /// not whatever VS Code had in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let path = info["projectPath"] as? String
        Task { @MainActor in
            if let path, !path.isEmpty {
                self.projects.focus(path: path)
            } else {
                // Threshold notifications carry no project: show the panel instead.
                self.panel.show()
            }
            completionHandler()
        }
    }

    // MARK: - Surfaces

    /// One surface *kind* at a time — notch mode may still put a surface on
    /// several screens. Falls back to the floating panel if there is no display to
    /// attach to at all, so the app is never left with nothing visible.
    ///
    /// `isInitial` separates "restore what was on screen last time" from "the user
    /// just picked this surface". Choosing the floating panel is a request to see
    /// it; a launch is not, so a panel deliberately hidden before quitting stays
    /// hidden.
    private func applyDisplayMode(isInitial: Bool = false) {
        switch settings.displayMode {
        case .notch where notch.isSupported:
            // `suspend`, not `hide`: the panel is merely not the active surface.
            panel.suspend()
            notch.show()
        case .notch:
            Log.error("Nessuno schermo disponibile: torno al pannello flottante")
            settings.displayMode = .floating
            notch.hide()
            panel.show()
        case .floating:
            notch.hide()
            if isInitial {
                panel.showIfEnabled()
            } else {
                panel.show()
            }
        }
    }

    /// Cycles through both surfaces, logging the menu and what is actually on
    /// screen. Leaves the mode as it found it.
    private func runSurfaceSelfTest() async {
        let original = settings.displayMode

        for mode in [DisplayMode.notch, .floating] {
            settings.displayMode = mode
            // The mode is applied through a publisher, so give it a turn to land.
            try? await Task.sleep(nanoseconds: 700_000_000)
            Log.info(
                "[selftest] modo=\(mode.rawValue) pannello=\(panel.isVisible ? "visibile" : "nascosto") notch=\(notch.isVisible ? "visibile" : "nascosto") preferenza panelVisible=\(settings.panelVisible)"
            )
            menuBar.logStructure()
        }

        settings.displayMode = original
        try? await Task.sleep(nanoseconds: 300_000_000)
        Log.info("[selftest] modo ripristinato: \(original.rawValue)")

        guard settings.displayMode == .notch else { return }

        // Does changing the size while running actually move the window? The
        // settings→geometry→window chain has three hops and a publisher in it.
        let originalSize = settings.notchSize
        for size in [CGSize(width: 260, height: 48), CGSize(width: 120, height: 26), originalSize] {
            settings.notchWidth = size.width
            settings.notchHeight = size.height
            try? await Task.sleep(nanoseconds: 400_000_000)
            Log.info("[selftest] richiesto \(Int(size.width))×\(Int(size.height)) → \(notch.describeSurfaces())")
        }
    }

    // MARK: - Hook installation

    /// Runs the bundled installer and reports the outcome. Confirmation first:
    /// this edits the user's ~/.claude/settings.json.
    private func installHooks() {
        let alreadyInstalled = HookInstaller.areHooksInstalled()

        let confirm = NSAlert()
        confirm.messageText = alreadyInstalled
            ? "Reinstallare gli hook di Claude Code?"
            : "Installare gli hook di Claude Code?"
        confirm.informativeText = """
        Verranno aggiunte voci in ~/.claude/settings.json per gli eventi di \
        Claude Code, così Claude Live può mostrare lo stato per progetto.

        Il file viene salvato in backup prima della modifica e gli hook già \
        presenti non vengono toccati.
        """
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: alreadyInstalled ? "Reinstalla" : "Installa")
        confirm.addButton(withTitle: "Annulla")

        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let result = HookInstaller.run()

        let outcome = NSAlert()
        switch result {
        case .success(let log):
            outcome.messageText = "Hook installati"
            outcome.informativeText = log.isEmpty
                ? "Riavvia le sessioni Claude Code aperte perché li carichino."
                : log + "\nRiavvia le sessioni Claude Code aperte perché li carichino."
            outcome.alertStyle = .informational
        case .failure(let message):
            outcome.messageText = "Installazione non riuscita"
            outcome.informativeText = message
            outcome.alertStyle = .warning
        }
        outcome.addButton(withTitle: "OK")
        outcome.runModal()

        // Keep the wizard's status rows honest after an install.
        onboardingWindow?.refreshChecks()
    }
}
