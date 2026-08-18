import AppKit

/// The window that hosts the notch surface.
///
/// Differs from `FloatingPanel` in the two ways that matter here: it sits
/// *above* the menu bar (so its strips can occupy the area beside the notch),
/// and it never moves — position is derived from screen geometry, not from
/// dragging.
final class NotchWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false

        // The menu bar lives at `.mainMenu` (24); `.statusBar` (25) is the
        // lowest level that reliably draws over it.
        level = .statusBar

        collectionBehavior = Self.stickyBehavior

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isMovable = false

        isOpaque = false
        backgroundColor = .clear
        // A shadow would draw a halo around the strips and give away that this
        // is a window rather than part of the notch.
        hasShadow = false

        animationBehavior = .none
        isRestorable = false

        // Always dark: the surface is black by definition.
        appearance = NSAppearance(named: .darkAqua)
    }

    /// Visible on every Space and over full-screen apps, and never dragged along
    /// by Mission Control.
    static let stickyBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

    /// Re-asserts the window's presence on the current Space.
    ///
    /// `canJoinAllSpaces` is not retroactive: it puts the window on the Spaces
    /// that exist when it is ordered in, and a Space **created afterwards** never
    /// gets it. On that Space the window is not sticky at all — it stays attached
    /// to the Space it came from and slides away with it, which is what "the notch
    /// follows the desktop instead of staying put" looks like.
    ///
    /// Ordering the window front again after a Space change is what attaches it to
    /// the new one. The behaviour is re-applied at the same time, so the window
    /// cannot end up on screen with a stale one.
    func reassertSpacePresence() {
        collectionBehavior = Self.stickyBehavior
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { /* Esc must not close it */ }
}
