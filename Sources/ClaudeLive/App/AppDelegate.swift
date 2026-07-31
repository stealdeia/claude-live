import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
            onInstallHooks: { [weak self] in self?.installHooks() }
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
            onInstallHooks: { [weak self] in self?.installHooks() },
            onCheckForUpdates: { [weak self] in self?.updates.checkForUpdates() },
            onShowOnboarding: { [weak self] in self?.onboardingWindow.show() }
        )

        if settings.notificationsEnabled || settings.notifyOnWaitingInput {
            notifier.requestAuthorizationIfNeeded()
        }

        applyDisplayMode()
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
                guard self.settings.displayMode == .notch else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.notch.writeSnapshot(to: Paths.supportDirectory.appendingPathComponent("notch-collapsed.png"))
                self.notch.setExpanded(true)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self.notch.writeSnapshot(to: Paths.supportDirectory.appendingPathComponent("notch-expanded.png"))
                self.notch.setExpanded(false)
            }
        }

        // Numbers go stale across sleep; refresh as soon as the Mac wakes.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.monitor.refresh(reason: "risveglio") }
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

    // MARK: - Surfaces

    /// Exactly one surface is on screen at a time. Notch mode falls back to the
    /// floating panel when this Mac has no notch (or the lid is closed), so the
    /// app is never left with nothing visible.
    private func applyDisplayMode() {
        switch settings.displayMode {
        case .notch where notch.isSupported:
            panel.hide()
            notch.show()
        case .notch:
            Log.error("Nessuno schermo con notch: torno al pannello flottante")
            settings.displayMode = .floating
            notch.hide()
            panel.show()
        case .floating:
            notch.hide()
            panel.showIfEnabled()
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
