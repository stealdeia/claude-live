import AppKit
import SwiftUI

/// A plain window for the settings form. In an `LSUIElement` app we must
/// activate explicitly, otherwise the window opens behind everything.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: Settings
    private let monitor: UsageMonitor
    private let status: ClaudeStatusStore
    private let onInstallHooks: () -> Void

    private static let contentSize = NSSize(width: 480, height: 660)

    init(
        settings: Settings,
        monitor: UsageMonitor,
        status: ClaudeStatusStore,
        onInstallHooks: @escaping () -> Void
    ) {
        self.settings = settings
        self.monitor = monitor
        self.status = status
        self.onInstallHooks = onInstallHooks
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(
                settings: settings,
                monitor: monitor,
                status: status,
                onInstallHooks: onInstallHooks
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
}
