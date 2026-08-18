import AppKit

/// Where a notch surface goes, and how big it is.
///
/// Two flavours, deliberately handled by the same type so nothing downstream has
/// to branch on them:
///   * **physical** — a real cutout, measured from the screen. The middle gap is
///     the cutout itself and nothing is drawn there;
///   * **virtual** — an external monitor with no cutout. The middle gap is drawn
///     black like the rest, which is what makes a notch appear where the hardware
///     has none.
///
/// Measured on the built-in display of this machine (1512×982 at 0,0):
/// ```text
/// safeAreaInsets.top    32
/// auxiliaryTopLeftArea  0   … 665   (665pt)
/// auxiliaryTopRightArea 850 … 1512  (662pt)
/// → cutout 185pt wide, 32pt tall, x 665 … 850
/// ```
/// The notch is not necessarily on the *main* screen — here the main screen is
/// an external monitor and the cutout belongs to the laptop panel.
///
/// Holds no `NSScreen`: a screen object goes stale across a configuration change,
/// and everything needed (centre, top edge, name) is a plain value. That also
/// makes the type `Equatable`, which is how the controller decides whether a
/// surface needs rebuilding.
struct NotchGeometry: Equatable {
    /// Stable identifier of the host display, see `ScreenIdentity`.
    let screenID: String
    let screenName: String
    /// Rect of the cutout (physical) or of the drawn stand-in (virtual), in
    /// AppKit screen coordinates.
    let notchRect: CGRect
    /// Top edge of the host screen.
    let screenTopY: CGFloat
    let isVirtual: Bool

    /// Height of the collapsed bar.
    var barHeight: CGFloat { notchRect.height }

    // MARK: Sizing

    /// Ring diameter at scale 1. The label font is derived from it.
    static let baseRingDiameter: CGFloat = 21

    /// Gap between a ring and the edge of the cutout.
    static let ringInset: CGFloat = 7

    /// Fixed slot for the control on the outer side of each strip — the chevron on
    /// the left, the projects button on the right. The icon is *centred* in it.
    ///
    /// A slot rather than a `Spacer` because a spacer put all the slack on one
    /// side: the chevron ended up pressed against the ring with a visible gap out
    /// at the edge, and the projects button sat off-centre in whatever was left.
    /// With a slot, `stripWidth` is exactly slot + inset + ring — no unaccounted
    /// space anywhere.
    static let controlSlot: CGFloat = 32

    /// Space left outside a ring when the controls are hidden, so the ring does
    /// not sit flush against the edge of the black body.
    static let ringOuterPad: CGFloat = 8

    private static func stripChrome(showsControls: Bool) -> CGFloat {
        ringInset + (showsControls ? controlSlot : ringOuterPad)
    }

    /// Exposed for previews that need to draw the whole bar, not just the cutout.
    static func stripChromeWidth(showsControls: Bool) -> CGFloat {
        stripChrome(showsControls: showsControls)
    }

    /// Depth of the concave curve at the top corners — see `NotchShape`.
    ///
    /// It costs width: the black body is inset by this much on each side, so
    /// every window width below adds `2 × flareRadius` on top of the body it has
    /// to contain.
    static let flareRadius: CGFloat = 12

    /// Ring size for this surface. Capped so it cannot exceed the bar it lives in:
    /// the content is clipped by the window, so an oversized ring would be sliced
    /// rather than shrunk. The cap only bites on a deliberately short bar — at the
    /// standard 32pt it leaves the whole scale range intact.
    func ringDiameter(scale: Double) -> CGFloat {
        min(Self.baseRingDiameter * scale, barHeight - 2)
    }

    /// Width of one strip. Narrower when the chevron and the projects button are
    /// hidden: the whole bar shrinks with them, rather than keeping two empty
    /// slots of black beside the rings.
    func stripWidth(scale: Double, showsControls: Bool) -> CGFloat {
        Self.stripChrome(showsControls: showsControls) + ringDiameter(scale: scale)
    }

    /// Black body of the collapsed surface: two strips hugging the cutout.
    func collapsedBodyWidth(scale: Double, showsControls: Bool) -> CGFloat {
        stripWidth(scale: scale, showsControls: showsControls) * 2 + notchRect.width
    }

    /// Window width when collapsed — the body plus the two flares.
    func collapsedWidth(scale: Double, showsControls: Bool) -> CGFloat {
        collapsedBodyWidth(scale: scale, showsControls: showsControls) + Self.flareRadius * 2
    }

    /// Body width when expanded — deliberately much wider than collapsed, so
    /// opening the panel reads as the notch growing outwards as well as downwards.
    static let expandedBodyWidth: CGFloat = 600

    /// Window width when expanded.
    static var expandedWidth: CGFloat { expandedBodyWidth + flareRadius * 2 }

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

    /// Radius of the bottom corners, echoing the cutout's own rounding.
    static let collapsedCornerRadius: CGFloat = 9
    static let expandedCornerRadius: CGFloat = 22

    /// Horizontal centre of the notch — every surface is centred on it.
    var centerX: CGFloat { notchRect.midX }

    /// Window frame for a given content size: centred on the cutout, top edge
    /// flush with the screen top. The window tracks the content exactly, so no
    /// transparent area exists to intercept clicks meant for other apps.
    func frame(for size: CGSize) -> CGRect {
        CGRect(
            x: centerX - size.width / 2,
            y: screenTopY - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: Configurable notch size

    /// Default size of the notch's middle section, i.e. of the cutout or of the
    /// stand-in drawn in its place.
    ///
    /// Close to the real cutout (185×32) so the surface looks the same on every
    /// display. The height is not derived from the menu bar: on this setup the
    /// external monitors report `visibleFrame == frame`, i.e. no menu bar inset at
    /// all, so there is nothing to measure.
    static let defaultNotchSize = CGSize(width: 170, height: 32)

    /// Bounds for the configurable size. The lower height bound keeps the 18pt
    /// controls inside the bar; the upper bounds stop a stray value from covering
    /// half the screen.
    /// Declared in `Double` because that is what the settings store; the geometry
    /// converts. `ClosedRange<CGFloat>` and `ClosedRange<Double>` are distinct
    /// types even where the scalars convert implicitly.
    static let widthRange: ClosedRange<Double> = 60...600
    static let heightRange: ClosedRange<Double> = 24...72

    // MARK: Discovery

    /// True when the screen has a real cutout.
    ///
    /// `auxiliaryTopLeftArea` is nil on screens without one, which makes it a
    /// more precise test than `safeAreaInsets.top`: the latter is also non-zero
    /// in some external configurations.
    static func hasPhysicalNotch(_ screen: NSScreen) -> Bool {
        physicalNotchRect(of: screen) != nil
    }

    /// Size of this screen's cutout, if it has one.
    static func cutoutSize(of screen: NSScreen) -> CGSize? {
        physicalNotchRect(of: screen)?.size
    }

    private static func physicalNotchRect(of screen: NSScreen) -> CGRect? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              screen.safeAreaInsets.top > 0
        else { return nil }

        let width = screen.frame.width - left.width - right.width
        guard width > 1 else { return nil }

        return CGRect(
            x: left.maxX,
            y: screen.frame.maxY - left.height,
            width: width,
            height: left.height
        )
    }

    /// Geometry for any screen: its own cutout if it has one, a drawn one if not.
    ///
    /// On a screen **with** a cutout the requested size is a **floor**, not a value
    /// to ignore. The hardware sets the minimum for a physical reason: a bar
    /// narrower than the hole would put the rings inside it, where nothing is
    /// displayed, and a shorter one would leave the hole's lower edge sticking out
    /// below the bar. Above those minimums the bar simply grows, so the setting
    /// works on every display — it just cannot make a real notch smaller than it is.
    static func geometry(for screen: NSScreen, notchSize: CGSize = defaultNotchSize) -> NotchGeometry {
        let identifier = ScreenIdentity.identifier(for: screen)
        var width = CGFloat(Double(notchSize.width).clamped(to: widthRange))
        var height = CGFloat(Double(notchSize.height).clamped(to: heightRange))

        if let cutout = physicalNotchRect(of: screen) {
            width = max(width, cutout.width)
            height = max(height, cutout.height)
            // Centred on the *cutout*, not on the screen: the extra width has to
            // grow symmetrically around the hole to stay aligned with it.
            return NotchGeometry(
                screenID: identifier,
                screenName: screen.localizedName,
                notchRect: CGRect(
                    x: cutout.midX - width / 2,
                    y: screen.frame.maxY - height,
                    width: width,
                    height: height
                ),
                screenTopY: screen.frame.maxY,
                isVirtual: false
            )
        }

        let rect = CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
        return NotchGeometry(
            screenID: identifier,
            screenName: screen.localizedName,
            notchRect: rect,
            screenTopY: screen.frame.maxY,
            isVirtual: true
        )
    }

    /// The cutout of the connected screen that has one, for showing its real
    /// measurements in Settings.
    static func physicalCutout() -> CGRect? {
        screenWithPhysicalNotch().flatMap(physicalNotchRect(of:))
    }

    /// The screen with a physical cutout, if any is connected.
    static func screenWithPhysicalNotch() -> NSScreen? {
        NSScreen.screens.first(where: hasPhysicalNotch)
    }

    /// Every screen the notch should currently appear on.
    ///
    /// Never returns empty while a display is connected. A selection that no
    /// longer resolves — the chosen monitor was unplugged, or nothing was ever
    /// chosen — falls back to the automatic behaviour instead of leaving the app
    /// with no visible surface at all.
    /// `notchSize` is asked per display identifier: sizes are per-screen, because
    /// one bar size across a 1512pt laptop panel and a 1920pt monitor is the wrong
    /// bar on at least one of them.
    static func geometries(
        selection: NotchScreenSelection,
        chosenIDs: [String],
        notchSize: (String) -> CGSize = { _ in defaultNotchSize }
    ) -> [NotchGeometry] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }

        // Every branch goes through here, so the requested size can never be
        // dropped on the way. It used to be: the automatic branch built its
        // geometry from a helper that took no size, so on a Mac with a cutout the
        // width and height settings did precisely nothing.
        func resolve(_ screen: NSScreen) -> NotchGeometry {
            geometry(for: screen, notchSize: notchSize(ScreenIdentity.identifier(for: screen)))
        }

        switch selection {
        case .automatic:
            if let withNotch = screenWithPhysicalNotch() { return [resolve(withNotch)] }
            return [resolve(NSScreen.main ?? screens[0])]

        case .all:
            return screens.map(resolve)

        case .chosen:
            let chosen = screens.filter { chosenIDs.contains(ScreenIdentity.identifier(for: $0)) }
            guard !chosen.isEmpty else {
                Log.debug("Nessuno schermo scelto è collegato: uso l'automatico", category: .panel)
                return geometries(selection: .automatic, chosenIDs: [], notchSize: notchSize)
            }
            return chosen.map(resolve)
        }
    }

    /// Notch mode needs a display, and nothing more: a screen without a cutout
    /// gets a drawn one.
    static var isAvailable: Bool { !NSScreen.screens.isEmpty }
}
