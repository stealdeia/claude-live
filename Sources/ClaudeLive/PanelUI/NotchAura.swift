import AppKit
import SwiftUI
import QuartzCore

/// The soft shadow that detaches the expanded panel from whatever is behind it.
///
/// ## Why a second window
///
/// The notch window is exactly as large as what it paints — that is the invariant
/// that stops it from swallowing clicks meant for other apps (see `NotchSurface`).
/// A shadow needs room *outside* the shape, so there is nowhere to put it: growing
/// the notch window would recreate the transparent-margin bug, and `hasShadow` on
/// the window can only be on or off, which is precisely the "appears all at once"
/// this is meant to avoid.
///
/// So the shadow lives in its own window, ordered directly below the notch one and
/// **transparent to the mouse** (`ignoresMouseEvents`), which is the one kind of
/// oversized transparent window that cannot steal an event: the click is not
/// discarded, it is never offered to us in the first place.
final class NotchAuraWindow: NSPanel {
    /// Room around the notch shape for the blur to spread into. Only to the sides
    /// and below: the shape's top edge is the screen's, so anything above is off
    /// screen anyway.
    static let margin: CGFloat = 60

    private let shadowView = NotchShadowView()

    /// The notification strip. Lives here rather than in the notch window because
    /// it has to be drawn *outside* the shape — see `NotchGlowView`.
    private let glowHost = NSHostingView(rootView: NotchGlowView(
        palette: .solid(.waiting),
        bottomCornerRadius: NotchGeometry.collapsedCornerRadius,
        horizontalMargin: NotchAuraWindow.margin,
        bottomMargin: NotchAuraWindow.margin,
        fixedPhase: nil
    ))
    private var glow: NotchGlowPalette?
    private var cornerRadius: CGFloat = NotchGeometry.collapsedCornerRadius

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = NotchWindow.stickyBehavior

        isOpaque = false
        backgroundColor = .clear
        // Our own drawn shadow is the whole point; AppKit's would outline the
        // window itself.
        hasShadow = false
        // The reason this window is allowed to be bigger than what it paints.
        ignoresMouseEvents = true
        animationBehavior = .none
        isRestorable = false

        contentView = shadowView

        glowHost.frame = shadowView.bounds
        glowHost.autoresizingMask = [.width, .height]
        // Hidden, not merely transparent: a `TimelineView` that is on screen keeps
        // asking for a frame every refresh, and there is nothing to animate when no
        // project is waiting.
        glowHost.isHidden = true
        shadowView.addSubview(glowHost)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Frame for a given notch window frame: the same rect, grown sideways and
    /// downwards by `margin`.
    static func frame(forNotchFrame notch: CGRect) -> CGRect {
        CGRect(
            x: notch.minX - margin,
            y: notch.minY - margin,
            width: notch.width + margin * 2,
            height: notch.height + margin
        )
    }

    /// Re-cuts the shadow to the notch's current shape. Called on every frame of
    /// the open/close animation, right after the notch window is resized, so the
    /// two can never drift apart.
    func reshape(notchSize: CGSize, bottomCornerRadius: CGFloat) {
        shadowView.reshape(notchSize: notchSize, bottomCornerRadius: bottomCornerRadius)
        // Called on every frame of the open animation, and re-rendering SwiftUI at
        // that rate for a value that only ever takes two values would be waste.
        guard cornerRadius != bottomCornerRadius else { return }
        cornerRadius = bottomCornerRadius
        refreshGlow()
    }

    /// Nil turns the signal off.
    func setGlow(_ palette: NotchGlowPalette?) {
        guard glow != palette else { return }
        glow = palette
        refreshGlow()
    }

    private func refreshGlow() {
        glowHost.isHidden = glow == nil
        guard let glow else { return }
        glowHost.rootView = NotchGlowView(
            palette: glow,
            bottomCornerRadius: cornerRadius,
            horizontalMargin: Self.margin,
            bottomMargin: Self.margin,
            fixedPhase: nil
        )
    }

    func setShadow(visible: Bool, duration: TimeInterval) {
        shadowView.setShadow(visible: visible, duration: duration)
    }
}

/// Draws nothing but a shadowLayer.
///
/// A `CALayer` with a `shadowPath` renders its shadow whatever its contents are,
/// so this view is fully transparent and still casts one — no duplicate of the
/// black shape to keep in sync, and nothing to see through the panel it sits
/// behind.
private final class NotchShadowView: NSView {
    /// Opacity when shown. Tuned on a light wallpaper: much more and the panel
    /// looks like it is floating a foot above the screen.
    private static let opacity: Float = 0.55

    private let shadowLayer = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shadowLayer)

        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowRadius = 22
        shadowLayer.shadowOffset = CGSize(width: 0, height: -10)
        shadowLayer.shadowOpacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func reshape(notchSize: CGSize, bottomCornerRadius: CGFloat) {
        let path = NotchShape(
            topFlareRadius: NotchGeometry.flareRadius,
            bottomCornerRadius: bottomCornerRadius
        )
        .path(in: CGRect(origin: .zero, size: notchSize))
        .cgPath

        // `NotchShape` measures y downwards, an `NSView` upwards, and the shape
        // hangs from the top of this view: flip, then drop it into place.
        let margin = NotchAuraWindow.margin
        var flip = CGAffineTransform(scaleX: 1, y: -1)
            .concatenating(CGAffineTransform(translationX: margin, y: notchSize.height))

        CATransaction.begin()
        // The path follows the window frame, which is already being animated a
        // step at a time; letting Core Animation interpolate it too would make the
        // shadow lag behind the shape it belongs to.
        CATransaction.setDisableActions(true)
        shadowLayer.frame = CGRect(
            x: 0,
            y: bounds.height - notchSize.height,
            width: bounds.width,
            height: notchSize.height
        )
        shadowLayer.shadowPath = path.copy(using: &flip)
        CATransaction.commit()
    }

    func setShadow(visible: Bool, duration: TimeInterval) {
        let target: Float = visible ? Self.opacity : 0
        guard shadowLayer.shadowOpacity != target else { return }

        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = shadowLayer.shadowOpacity
        fade.toValue = target
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shadowLayer.add(fade, forKey: "shadowOpacity")
        shadowLayer.shadowOpacity = target
    }
}
