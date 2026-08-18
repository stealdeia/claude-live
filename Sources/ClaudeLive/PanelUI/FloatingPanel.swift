import AppKit

/// Borderless, always-on-top, non-activating panel.
///
/// "Non-activating" is the important part: clicking a button inside must not
/// pull focus away from VS Code or the terminal. `.nonactivatingPanel` plus
/// `canBecomeKey == true` gives us clickable controls without app activation.
final class FloatingPanel: NSPanel {
    /// Called after a user drag finishes, so the controller can persist the origin.
    var onDragEnded: ((CGPoint) -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false

        // `.statusBar` keeps it above ordinary windows (and above other floating
        // panels) without fighting with menus or the Dock.
        level = .statusBar

        collectionBehavior = Self.stickyBehavior

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        animationBehavior = .utilityWindow

        // Menu-bar-only apps have no windows to restore; skip the machinery.
        isRestorable = false
    }

    /// Follow the user across Spaces, and stay visible over full-screen apps.
    static let stickyBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    /// Re-attaches the panel to the Space that just became active.
    ///
    /// `canJoinAllSpaces` only covers the Spaces that existed when the window was
    /// ordered in; one created later never gets it unless the window is ordered
    /// front again. See `NotchWindow.reassertSpacePresence`.
    func reassertSpacePresence() {
        collectionBehavior = Self.stickyBehavior
        orderFrontRegardless()
    }

    /// Needed so buttons and controls inside the panel respond to clicks.
    override var canBecomeKey: Bool { true }

    /// Never becomes the main window — that is what would steal focus.
    override var canBecomeMain: Bool { false }

    /// Esc must not close the panel (borderless panels cancel by default).
    override func cancelOperation(_ sender: Any?) { /* intentionally ignored */ }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onDragEnded?(frame.origin)
    }
}
