import AppKit
import SwiftUI

/// Hosts the first-run wizard. Same pattern as the settings window: an
/// `LSUIElement` app has to activate explicitly or the window opens behind
/// everything.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let state = OnboardingState()
    private let settings: Settings
    private let onInstallHooks: () -> Void

    init(settings: Settings, onInstallHooks: @escaping () -> Void) {
        self.settings = settings
        self.onInstallHooks = onInstallHooks
    }

    func show() {
        state.checkAll()

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: OnboardingView(
                state: state,
                settings: settings,
                onInstallHooks: onInstallHooks,
                onFinish: { [weak self] in self?.finish() }
            )
        )
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = "Configurazione di Claude Live"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .normal

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Renders the wizard to a PNG, for the same reason `NotchController` can:
    /// checking this UI from a script otherwise needs the Screen Recording
    /// permission, while drawing our own view needs nothing.
    func writeSnapshot(to url: URL) {
        guard let view = window?.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        Log.info("Snapshot onboarding salvato: \(url.lastPathComponent) (\(Int(view.bounds.width))×\(Int(view.bounds.height)))")
    }

    /// Re-runs the checks, so the settings window and the panel reflect anything
    /// the wizard changed.
    func refreshChecks() {
        state.checkAll()
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        window?.close()
        Log.info("Configurazione guidata completata")
    }
}
