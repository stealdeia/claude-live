import AppKit
import SwiftUI
import ClaudeLiveKit

/// One-shot requests from outside the settings window — currently just "open the
/// screens sheet", so the menu bar can jump straight to it instead of asking the
/// user to find the button.
@MainActor
final class SettingsUIState: ObservableObject {
    @Published var requestsNotchScreens = false
}

/// A plain window for the settings form. In an `LSUIElement` app we must
/// activate explicitly, otherwise the window opens behind everything.
@MainActor
final class SettingsWindowController {
    let ui = SettingsUIState()

    private var window: NSWindow?
    private let settings: Settings
    private let monitor: UsageMonitor
    private let projects: ProjectsMonitor
    private let status: ClaudeStatusStore
    private let updates: UpdateController
    private let onInstallHooks: () -> Void
    private let onShowOnboarding: () -> Void
    private let onTogglePanelVisibility: () -> Void
    private let onPreviewGlow: (NotchGlowPalette) -> Void
    private let onQuit: () -> Void

    private static let contentSize = NSSize(width: 480, height: 660)

    init(
        settings: Settings,
        monitor: UsageMonitor,
        projects: ProjectsMonitor,
        status: ClaudeStatusStore,
        updates: UpdateController,
        onInstallHooks: @escaping () -> Void,
        onShowOnboarding: @escaping () -> Void,
        onTogglePanelVisibility: @escaping () -> Void,
        onPreviewGlow: @escaping (NotchGlowPalette) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.settings = settings
        self.monitor = monitor
        self.projects = projects
        self.status = status
        self.updates = updates
        self.onInstallHooks = onInstallHooks
        self.onShowOnboarding = onShowOnboarding
        self.onTogglePanelVisibility = onTogglePanelVisibility
        self.onPreviewGlow = onPreviewGlow
        self.onQuit = onQuit
    }

    /// `showingNotchScreens` opens the screens sheet as soon as the window is up.
    func show(showingNotchScreens: Bool = false) {
        defer { if showingNotchScreens { ui.requestsNotchScreens = true } }
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(
                settings: settings,
                ui: ui,
                monitor: monitor,
                projects: projects,
                status: status,
                updates: updates,
                onInstallHooks: onInstallHooks,
                onShowOnboarding: onShowOnboarding,
                onTogglePanelVisibility: onTogglePanelVisibility,
                onPreviewGlow: onPreviewGlow,
                onQuit: onQuit
            )
        )

        // The window owns the size here; SwiftUI must not try to drive it.
        // Letting the hosting controller propose a size is what clipped the
        // form's content against a narrower window.
        hosting.sizingOptions = []
        hosting.view.frame = NSRect(origin: .zero, size: Self.contentSize)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Impostazioni Claude Live"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.contentSize)
        window.contentMinSize = NSSize(width: 420, height: 360)
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.center()

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Renders the screens sheet to a PNG. Separate from the form's snapshot: a
    /// sheet is a different window, so `contentView` of the settings window does not
    /// contain it.
    func writeNotchScreensSnapshot(to url: URL) {
        let hosting = NSHostingController(
            rootView: NotchScreensView(settings: settings) {}
        )
        hosting.view.frame = NSRect(x: 0, y: 0, width: 560, height: 660)
        hosting.view.layoutSubtreeIfNeeded()
        guard let rep = hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds) else { return }
        hosting.view.cacheDisplay(in: hosting.view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        Log.info("Snapshot schermi notch salvato: \(url.path)")
    }

    /// Renders the form to a PNG, for checking the layout from a script.
    ///
    /// Worth having permanently: this window has already been shipped once with
    /// content clipped against a narrower window, and that is invisible from the
    /// code alone.
    func writeSnapshot(to url: URL) {
        show()
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        Log.info("Snapshot impostazioni salvato: \(url.path)")
    }
}
