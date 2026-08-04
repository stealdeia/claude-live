import SwiftUI

/// The outline of the notch surface: concave flares at the top, rounded corners
/// at the bottom.
///
/// ```text
///  ┌──╮                              ╭──┐   ← screen top: the shape reaches the
///  │  ╰──────────────────────────────╯  │     full width only at the very edge
///  │        strip   cutout   strip       │
///  ╰────────────────────────────────────╯   ← convex bottom corners
/// ```
///
/// The two top curves are the point of this shape. A hard 90° corner announces
/// "this is a window sitting on the menu bar"; a concave fillet reads as the
/// notch itself flaring outwards, which is how macOS rounds the cutout and how
/// the eye expects black-on-menu-bar to behave.
///
/// Note the consequence for layout: the shape's *body* is inset by
/// `topFlareRadius` on both sides, so the window has to be that much wider than
/// the content and the content that much narrower than the window. Everything
/// derived from `NotchGeometry` already accounts for it.
struct NotchShape: Shape {
    /// Depth of the concave curve at the top corners.
    var topFlareRadius: CGFloat
    /// Radius of the convex bottom corners.
    var bottomCornerRadius: CGFloat

    /// Only the bottom radius changes (collapsed → expanded), so it is the only
    /// thing that needs to interpolate.
    var animatableData: CGFloat {
        get { bottomCornerRadius }
        set { bottomCornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // Clamped so a very narrow or very short surface degrades into something
        // still drawable rather than producing a self-crossing path.
        let flare = min(topFlareRadius, rect.width / 2, rect.height)
        let corner = min(bottomCornerRadius, max(0, rect.width / 2 - flare), max(0, rect.height - flare))

        let bodyLeft = rect.minX + flare
        let bodyRight = rect.maxX - flare

        var path = Path()

        // Top-left: leave the screen edge horizontally and curve *into* the
        // shape, so the black narrows as it descends.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: bodyLeft, y: rect.minY + flare),
            control: CGPoint(x: bodyLeft, y: rect.minY)
        )

        path.addLine(to: CGPoint(x: bodyLeft, y: rect.maxY - corner))
        path.addQuadCurve(
            to: CGPoint(x: bodyLeft + corner, y: rect.maxY),
            control: CGPoint(x: bodyLeft, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: bodyRight - corner, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bodyRight, y: rect.maxY - corner),
            control: CGPoint(x: bodyRight, y: rect.maxY)
        )

        path.addLine(to: CGPoint(x: bodyRight, y: rect.minY + flare))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: bodyRight, y: rect.minY)
        )

        // Closing draws the top edge back at full width, which is what makes the
        // flare read as an extension of the menu bar rather than a bevel.
        path.closeSubpath()
        return path
    }
}
