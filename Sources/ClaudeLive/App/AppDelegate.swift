import AppKit
import Combine
import UserNotifications
import ClaudeLiveKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var settings: Settings!
    private var monitor: UsageMonitor!
    private var projects: ProjectsMonitor!
    private var status: ClaudeStatusStore!
    private var frontWatcher: FrontProjectWatcher!
    private var remote: RemotePublisher!
    private var notifier: UsageNotifier!
    private var alertNotifier: ClaudeAlertNotifier!
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

        // Before any window can appear: without a main menu, Cmd+V does nothing
        // in every text field the app has.
        EditMenu.install()

        settings = Settings.shared
        updates = UpdateController()
        notifier = UsageNotifier(settings: settings)
        alertNotifier = ClaudeAlertNotifier(settings: settings)

        monitor = UsageMonitor(settings: settings, notifier: notifier)
        projects = ProjectsMonitor(settings: settings)
        status = ClaudeStatusStore(settings: settings, notifier: alertNotifier)
        frontWatcher = FrontProjectWatcher(status: status, settings: settings)
        // Observes the same stores the panel draws from, so the phone and the
        // panel cannot disagree. Publishes nothing until switched on.
        remote = RemotePublisher(settings: settings, status: status, usage: monitor)

        onboardingWindow = OnboardingWindowController(
            settings: settings,
            onInstallHooks: { [weak self] in self?.installHooks() }
        )

        settingsWindow = SettingsWindowController(
            settings: settings,
            monitor: monitor,
            projects: projects,
            status: status,
            remote: remote,
            updates: updates,
            onInstallHooks: { [weak self] in self?.installHooks() },
            onShowOnboarding: { [weak self] in self?.onboardingWindow.show() },
            // Evaluated when tapped, by which point `panel` exists — it is built a
            // few lines below this.
            onTogglePanelVisibility: { [weak self] in self?.togglePanelVisibility() },
            onPreviewGlow: { [weak self] palette in self?.notch.previewGlow(palette) },
            onQuit: { NSApp.terminate(nil) }
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
            onTogglePanel: { [weak self] in self?.togglePanelVisibility() },
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
        frontWatcher.start()

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

                // The notification strip, one file per phase and per palette.
                let collapsed = CGSize(width: 281, height: 32)
                let expanded = CGSize(width: 624, height: 243)
                NotchGlowFilmstrip.write(
                    to: Paths.supportDirectory,
                    notchSize: collapsed,
                    bottomCornerRadius: NotchGeometry.collapsedCornerRadius,
                    palette: .solid(.done),
                    phases: [0, 0.35, 0.7, 1],
                    name: "verde"
                )
                NotchGlowFilmstrip.write(
                    to: Paths.supportDirectory,
                    notchSize: collapsed,
                    bottomCornerRadius: NotchGeometry.collapsedCornerRadius,
                    palette: .rainbow,
                    phases: [0.7],
                    name: "arcobaleno"
                )
                NotchGlowFilmstrip.write(
                    to: Paths.supportDirectory,
                    notchSize: collapsed,
                    bottomCornerRadius: NotchGeometry.collapsedCornerRadius,
                    palette: .blend(.waiting, .failed),
                    phases: [0.7],
                    name: "sfumatura"
                )
                NotchGlowFilmstrip.write(
                    to: Paths.supportDirectory,
                    notchSize: expanded,
                    bottomCornerRadius: NotchGeometry.expandedCornerRadius,
                    palette: .solid(.waiting),
                    phases: [0.55],
                    name: "aperto"
                )

                // Lights the real strip on the real notch for a while, so a run of
                // the snapshot diagnostic also shows it moving on screen.
                self.notch.previewGlow(.solid(.done), seconds: 12)

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

        // Opt-in via CLAUDELIVE_TEST_NOTIFICATION=1: posts the sound preview with
        // the app deliberately **frontmost**, which is the case that used to fail
        // silently, and logs what the notification centre ended up holding.
        if ProcessInfo.processInfo.environment["CLAUDELIVE_TEST_NOTIFICATION"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                NSApp.activate(ignoringOtherApps: true)
                NotificationSound.preview(self.settings.notificationSound)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await NotificationSound.logDeliveryDiagnostics()
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
            // Dark wake fires this too, so the refresh waits for the display
            // rather than being spent while it is still off — see
            // `refreshAfterWake`.
            Task { @MainActor in await self?.monitor.refreshAfterWake() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        projects?.stop()
        status?.stop()
        frontWatcher?.stop()
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

    /// Opening the app while it is already running shows Settings.
    ///
    /// This is the escape hatch for a hidden menu bar item: double-clicking Claude
    /// Live in the Finder is the one gesture that works no matter what is on screen,
    /// and without it "hide the icon" could be a one-way door.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        settingsWindow.show()
        return true
    }

    /// Brings the *active* surface to the user's attention.
    ///
    /// Whatever the reason for showing something — a tapped notification today —
    /// it must be the surface the user chose. Calling `panel.show()` here was the
    /// bug: in notch mode it put the floating panel on screen **next to** the
    /// notch, and nothing ever took it away again. Worse, `show()` records
    /// `panelVisible = true`, so the state survived a restart and the only way out
    /// was switching to the floating panel and back.
    private func revealActiveSurface() {
        guard settings.displayMode == .notch, notch.isSupported else {
            panel.show()
            return
        }
        // The notch is always on screen; what it can do is open its detail, which
        // is where the numbers the notification is about actually are. A click
        // anywhere else closes it again.
        notch.setExpanded(true)
    }

    // MARK: - Reachability

    /// Toggling the panel is also a reachability decision, so it goes through here.
    private func togglePanelVisibility() {
        panel.toggleVisibility()
        ensureReachable()
    }

    /// Guarantees at least one way into the app.
    ///
    /// With the menu bar item hidden, the surface's gear button is how Settings is
    /// reached — so hiding the surface as well would leave nothing to click, and the
    /// state is persisted, so a relaunch would come back just as unreachable. Rather
    /// than forbid the combination, the icon comes back: it is the one that was
    /// switched off for tidiness, not the one being used.
    private func ensureReachable() {
        guard !settings.showMenuBarIcon else { return }
        let surfaceVisible = settings.displayMode == .notch ? notch.isVisible : panel.isVisible
        guard !surfaceVisible else { return }
        settings.showMenuBarIcon = true
        Log.info("Icona nella barra dei menu ripristinata: era l'unico modo di raggiungere l'app")
    }

    // MARK: - Notifications

    /// Shows the banner even when Claude Live is the active application.
    ///
    /// Without this, macOS delivers a notification posted while the app is in the
    /// foreground **silently** — no banner, no sound, no error. Normally that is
    /// invisible here, because a menu-bar app is almost never the active one; the
    /// exception is anything posted from the Settings window, which is exactly
    /// where the sound preview lives. That was the bug: «Prova» did nothing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

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
                // Tapping the banner is as much an acknowledgement as clicking the
                // row, so the strip must not stay lit for something already seen.
                self.status.clearAlert(forPath: path)
            } else {
                // Threshold notifications carry no project, so there is nothing to
                // focus: show the numbers instead — on whichever surface is in use.
                self.revealActiveSurface()
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
        ensureReachable()
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

        // The regression that brought this check: tapping a notification with no
        // project called `panel.show()` unconditionally, so in notch mode the
        // floating panel appeared beside the notch and stayed there — across
        // restarts, because showing it records the preference.
        revealActiveSurface()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let leaked = settings.displayMode == .notch && panel.isVisible
        Log.info(
            "[selftest] notifica senza progetto: pannello=\(panel.isVisible ? "visibile" : "nascosto") "
            + "notch=\(notch.isVisible ? "visibile" : "nascosto") panelVisible=\(settings.panelVisible) "
            + "\(leaked ? "✗ il pannello è comparso sopra il notch" : "✓")"
        )
        if settings.displayMode == .notch { notch.setExpanded(false) }

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
