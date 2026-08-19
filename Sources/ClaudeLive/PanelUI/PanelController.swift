import AppKit
import SwiftUI
import Combine
import ClaudeLiveKit

/// Owns the floating panel: hosting, sizing, corner anchoring, drag persistence.
///
/// The SwiftUI layer knows nothing about AppKit; everything window-related lives
/// here, which is what will let a future notch surface reuse `PanelRootView`.
@MainActor
final class PanelController: NSObject {
    private let panel: FloatingPanel
    private let hosting: NSHostingController<PanelRootView>
    private let monitor: UsageMonitor
    private let projects: ProjectsMonitor
    private let status: ClaudeStatusStore
    private let settings: Settings

    private let onOpenSettings: () -> Void
    private let onInstallHooks: () -> Void
    private let onQuit: () -> Void

    /// Where the panel's top-left corner should stay while its height changes.
    private var desiredTopLeft: CGPoint?
    /// Last size we positioned for, so an identical resize notification is a no-op.
    private var lastPositionedSize: CGSize = .zero
    private var cancellables: Set<AnyCancellable> = []

    init(
        monitor: UsageMonitor,
        projects: ProjectsMonitor,
        status: ClaudeStatusStore,
        settings: Settings,
        onOpenSettings: @escaping () -> Void,
        onInstallHooks: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.projects = projects
        self.status = status
        self.settings = settings
        self.onOpenSettings = onOpenSettings
        self.onInstallHooks = onInstallHooks
        self.onQuit = onQuit

        hosting = NSHostingController(
            rootView: PanelRootView(
                monitor: monitor,
                projects: projects,
                status: status,
                settings: settings,
                actions: PanelActions()
            )
        )
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: PanelTheme.expandedWidth, height: 140))

        super.init()

        // Let the SwiftUI content drive the panel's size.
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.setFrameSize(NSSize(width: PanelTheme.expandedWidth, height: 140))
        panel.contentViewController = hosting

        // Now that all stored properties exist, wire the real actions in.
        hosting.rootView = PanelRootView(
            monitor: monitor,
            projects: projects,
            status: status,
            settings: settings,
            actions: makeActions()
        )

        panel.onDragEnded = { [weak self] origin in
            self?.handleDragEnded(origin: origin)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResize),
            name: NSWindow.didResizeNotification,
            object: panel
        )

        // Re-anchor when the display configuration changes (external monitor
        // plugged in, resolution change, Dock resize).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // A Space created after launch does not inherit `canJoinAllSpaces`;
        // switching to it is the moment to hand the panel over.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        // A collapse or an anchor change both need a reposition.
        settings.$panelCollapsed
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyPosition() }
            }
            .store(in: &cancellables)

        settings.$panelAnchor
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.desiredTopLeft = nil
                    self?.applyPosition()
                }
            }
            .store(in: &cancellables)

        applyTheme()
        settings.$theme
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyTheme() }
            }
            .store(in: &cancellables)
    }

    /// Set on the window, not the view tree: `NSVisualEffectView` takes its
    /// material from the window's appearance, so forcing only SwiftUI's
    /// colorScheme would leave a light background behind dark text.
    private func applyTheme() {
        panel.appearance = settings.theme.appearance
        Log.debug("Tema pannello: \(settings.theme.rawValue)", category: .panel)
    }

    private func makeActions() -> PanelActions {
        PanelActions(
            refreshNow: { [weak self] in
                guard let self else { return }
                Task { await self.monitor.refresh(reason: "manuale") }
                self.projects.refresh(reason: "manuale")
            },
            toggleCollapsed: { [weak self] in
                guard let self else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    self.settings.panelCollapsed.toggle()
                }
            },
            openSettings: onOpenSettings,
            installHooks: onInstallHooks,
            focusProject: { [weak self] path in self?.projects.focus(path: path) },
            quit: onQuit
        )
    }

    // MARK: - Visibility

    func showIfEnabled() {
        if settings.panelVisible { show() }
    }

    func show() {
        // Refused rather than obeyed when the notch is the surface in use.
        //
        // Not defensiveness for its own sake: showing the panel in notch mode puts
        // two surfaces on screen at once and records `panelVisible = true`, so it
        // outlives a restart and the only way back is switching mode twice. It has
        // reached users that way once already, from a tapped notification. Every
        // legitimate caller either is `applyDisplayMode` switching *to* the panel —
        // which sets the mode first — or is offered only in floating mode.
        guard settings.displayMode == .floating else {
            Log.error("Richiesta di mostrare il pannello ignorata: la superficie attiva è il notch", category: .panel)
            return
        }
        settings.panelVisible = true
        applyPosition()
        // `orderFrontRegardless` shows the panel without activating the app,
        // so whatever the user was typing in keeps focus.
        panel.orderFrontRegardless()
        Log.debug("Pannello mostrato", category: .panel)
    }

    /// The user asked for the panel to go away, so the preference changes with it.
    func hide() {
        settings.panelVisible = false
        panel.orderOut(nil)
        Log.debug("Pannello nascosto", category: .panel)
    }

    /// Takes the panel off screen **without** touching `panelVisible`: it is not
    /// the active surface right now, which says nothing about whether the user
    /// wants to see it when it is.
    ///
    /// This distinction is not academic. Switching to the notch used to call
    /// `hide()`, which recorded "the user hid the panel", so switching back showed
    /// nothing at all and the panel had to be summoned from the menu by hand.
    func suspend() {
        panel.orderOut(nil)
        Log.debug("Pannello sospeso (superficie non attiva)", category: .panel)
    }

    func toggleVisibility() {
        settings.panelVisible ? hide() : show()
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Positioning

    @objc private func panelDidResize() {
        // In notch mode this panel is ordered out but still hosted, so SwiftUI
        // keeps resizing it; repositioning it would be pure waste.
        guard panel.isVisible else { return }
        // SwiftUI re-renders often (a tool badge changing text is enough) and
        // most of those do not change the panel's size at all.
        guard panel.frame.size != lastPositionedSize else { return }
        applyPosition()
    }

    @objc private func screenParametersChanged() {
        desiredTopLeft = nil
        applyPosition()
    }

    /// Only re-orders a panel that is already meant to be on screen: showing a
    /// hidden panel because the user changed desktop would be a bug, not a fix.
    @objc private func activeSpaceChanged() {
        guard panel.isVisible else { return }
        panel.reassertSpacePresence()
    }

    /// Places the panel according to the current anchor, keeping the top edge
    /// stable when the content height changes (so collapsing feels like the
    /// panel shrinking upward rather than jumping).
    func applyPosition() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let margin = PanelTheme.screenMargin

        var origin: CGPoint
        switch settings.panelAnchor {
        case .topLeft:
            origin = CGPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin)
        case .topRight:
            origin = CGPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
        case .bottomLeft:
            origin = CGPoint(x: visible.minX + margin, y: visible.minY + margin)
        case .bottomRight:
            origin = CGPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
        case .free:
            // The stored value is the top-left corner, so it stays correct no
            // matter how tall the content currently is. Deriving it from the
            // bottom-left origin plus the *current* height (as this did before)
            // was the bug: at the first call the height was still the initial
            // placeholder, so every later resize shifted the panel.
            let topLeft = desiredTopLeft
                ?? settings.panelTopLeft
                ?? CGPoint(x: visible.maxX - size.width - margin, y: visible.maxY - margin)
            desiredTopLeft = topLeft
            origin = CGPoint(x: topLeft.x, y: topLeft.y - size.height)
        }

        // Never let the panel end up fully off-screen.
        origin.x = origin.x.clamped(to: visible.minX - size.width / 2 ... visible.maxX - size.width / 2)
        origin.y = origin.y.clamped(to: visible.minY - size.height / 2 ... visible.maxY - size.height / 2)

        lastPositionedSize = size
        if panel.frame.origin != origin {
            // Logged because unwanted repositioning is exactly the bug class this
            // method has already produced once.
            Log.debug(
                "Pannello riposizionato → \(Int(origin.x)),\(Int(origin.y)) (ancoraggio \(settings.panelAnchor.rawValue), \(Int(size.width))×\(Int(size.height)))",
                category: .panel
            )
            panel.setFrameOrigin(origin)
        }
    }

    private func handleDragEnded(origin: CGPoint) {
        let current = panel.frame
        let topLeft = CGPoint(x: current.minX, y: current.maxY)

        // Ignore mouse-ups that were not a drag: without this, every click on a
        // panel button would rewrite the stored position.
        if settings.panelAnchor == .free,
           let stored = settings.panelTopLeft,
           abs(stored.x - topLeft.x) < 1, abs(stored.y - topLeft.y) < 1 {
            return
        }

        // Any real drag switches the panel to free positioning.
        desiredTopLeft = topLeft
        settings.panelAnchor = .free
        settings.panelTopLeft = topLeft
        Log.debug("Pannello trascinato: top-left \(Int(topLeft.x)),\(Int(topLeft.y))", category: .panel)
    }
}
