import AppKit

/// Locates the physical notch and derives the rects the notch surface uses.
///
/// Measured on this machine (built-in Retina display, 1512×982 at 543,-982):
/// ```text
/// safeAreaInsets.top   32
/// auxiliaryTopLeftArea  543 … 1208   (665pt)
/// auxiliaryTopRightArea 1393 … 2055  (662pt)
/// → notch 185pt wide, 32pt tall, x 1208 … 1393
/// ```
/// Note the notch is not necessarily on the *main* screen: here the main screen
/// is an external BenQ, and the notch belongs to the laptop panel.
struct NotchGeometry {
    let screen: NSScreen
    /// Rect of the notch itself, in AppKit screen coordinates.
    let notchRect: CGRect
    /// Height of the reserved area at the top of the screen (the notch's height).
    var barHeight: CGFloat { notchRect.height }

    // MARK: Sizing

    /// Ring diameter at scale 1. The label font is derived from it.
    static let baseRingDiameter: CGFloat = 21

    /// Space each strip needs besides its ring: one control, the gaps and the
    /// paddings. Keeping it separate means the scale setting only has to grow the
    /// ring and the strip follows.
    private static let stripChrome: CGFloat = 44

    static func ringDiameter(scale: Double) -> CGFloat {
        baseRingDiameter * scale
    }

    static func stripWidth(scale: Double) -> CGFloat {
        stripChrome + ringDiameter(scale: scale)
    }

    /// Width of the collapsed surface: two strips hugging the cutout.
    func collapsedWidth(scale: Double) -> CGFloat {
        Self.stripWidth(scale: scale) * 2 + notchRect.width
    }

    /// Width when expanded — deliberately much wider than collapsed, so opening
    /// the panel reads as the notch growing outwards as well as downwards.
    static let expandedWidth: CGFloat = 600

    /// Opening is slower than closing and overshoots slightly; closing just
    /// settles. Asymmetry is deliberate — a bounce on the way out reads as the
    /// panel shrinking too far, which looks like a glitch rather than a flourish.
    static let openDuration: TimeInterval = 0.42
    static let closeDuration: TimeInterval = 0.26

    /// Bounce strength for opening. Scales the classic "ease-out-back" overshoot,
    /// which peaks at roughly 10% at strength 1 — far too much here. At 0.65 the
    /// panel passes its target by ~4.4%, about 12pt wider and 11pt taller at the
    /// peak: a visible settle rather than a wobble. Measured, not guessed: 0.35
    /// only reached 1.2%, which was imperceptible.
    static let openOvershoot: Double = 0.65

    /// Radius of the outer bottom corners, echoing the notch's own rounding.
    static let collapsedCornerRadius: CGFloat = 9
    static let expandedCornerRadius: CGFloat = 22

    /// Horizontal centre of the notch — every surface is centred on it.
    var centerX: CGFloat { notchRect.midX }

    /// Top edge of the screen the notch belongs to.
    var topY: CGFloat { screen.frame.maxY }

    /// Window frame for a given content size: centred on the cutout, top edge
    /// flush with the screen top. The window tracks the content exactly, so no
    /// transparent area exists to intercept clicks meant for other apps.
    func frame(for size: CGSize) -> CGRect {
        CGRect(
            x: centerX - size.width / 2,
            y: topY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The screen that has a notch, if any.
    ///
    /// `auxiliaryTopLeftArea` is nil on screens without a cutout, which makes it
    /// a more precise test than `safeAreaInsets.top`: the latter is also non-zero
    /// on some external configurations.
    static func current() -> NotchGeometry? {
        for screen in NSScreen.screens {
            guard let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea,
                  screen.safeAreaInsets.top > 0
            else { continue }

            let notchWidth = screen.frame.width - left.width - right.width
            guard notchWidth > 1 else { continue }

            let notchRect = CGRect(
                x: left.maxX,
                y: screen.frame.maxY - left.height,
                width: notchWidth,
                height: left.height
            )
            return NotchGeometry(screen: screen, notchRect: notchRect)
        }
        return nil
    }

    static var isAvailable: Bool { current() != nil }
}
