import SwiftUI
import AppKit

/// A colour for the glow, stored as components rather than as a `Color`.
///
/// `Color` is not `Codable` and cannot be interpolated, and both are needed: the
/// user's choice has to survive in `settings.json`, and a blend has to be computed
/// between two of them.
struct GlowRGB: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// Spelled out because declaring any other initialiser removes the memberwise
    /// one the rest of the file relies on.
    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From a `Color`, for the colour pickers in Settings.
    ///
    /// Converted through sRGB explicitly: a colour coming out of the system picker
    /// can be in any colour space, and reading components from it without converting
    /// returns nil for the ones that are not RGB — a silent fall back to black.
    init(_ color: Color) {
        let native = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(
            red: Double(native.redComponent),
            green: Double(native.greenComponent),
            blue: Double(native.blueComponent)
        )
    }

    static func blend(_ a: GlowRGB, _ b: GlowRGB, _ t: Double) -> GlowRGB {
        let t = t.clamped(to: 0...1)
        return GlowRGB(
            red: a.red + (b.red - a.red) * t,
            green: a.green + (b.green - a.green) * t,
            blue: a.blue + (b.blue - a.blue) * t
        )
    }

    /// Defaults, one per kind of event the glow reports.
    static let done = GlowRGB(red: 0.24, green: 0.85, blue: 0.45)
    static let waiting = GlowRGB(red: 1.00, green: 0.72, blue: 0.16)
    static let failed = GlowRGB(red: 1.00, green: 0.29, blue: 0.28)
}

/// How the strip is coloured along its length.
///
/// Always symmetric around the centre, because the light itself is: it leaves the
/// middle towards both ends at once, so a colour that ran left-to-right would put
/// a different one under each of the two travelling bands.
enum NotchGlowPalette: Equatable {
    /// One colour everywhere.
    case solid(GlowRGB)
    /// From the centre outwards.
    case blend(GlowRGB, GlowRGB)
    case rainbow

    /// `distance` is 0 at the centre of the notch and 1 at either end.
    func color(atDistance distance: Double) -> Color {
        switch self {
        case .solid(let c):
            return c.color
        case .blend(let inner, let outer):
            return GlowRGB.blend(inner, outer, distance).color
        case .rainbow:
            // Stops short of a full turn: 0…0.82 runs red → violet, while a full
            // 0…1 would come back to red and read as two red ends.
            return Color(hue: distance * 0.82, saturation: 0.95, brightness: 1.0)
        }
    }
}

/// The travelling light, as gradient stops.
///
/// Shared between the notch's strip and the rows of the project list, which is the
/// point: a row pulsing in a different rhythm from the notch would read as two
/// unrelated things happening at once, when it is one event being reported twice.
enum GlowBand {
    /// Half-width of the lit band, as a fraction of the half-length.
    static let band: Double = 0.34
    /// How lit the rest stays, so it reads as a strip with light running through it
    /// rather than as two dots chasing each other.
    static let floor: Double = 0.16
    /// Enough samples that the band's edges are smooth; the cost is one gradient
    /// either way.
    static let samples = 48

    /// One full out-and-back. Slow enough to read as breathing rather than as a
    /// warning light.
    static let period: TimeInterval = 2.6

    /// Out-and-back, eased at both ends so the light lingers at the centre and at
    /// the tips instead of snapping around.
    static func phase(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        let triangle = t < 0.5 ? t * 2 : (1 - t) * 2
        return triangle * triangle * (3 - 2 * triangle)
    }

    /// Brightness is a function of horizontal position — a Gaussian band centred at
    /// `distance == phase` — so one gradient draws both travelling bands at once and
    /// the symmetry costs nothing.
    static func stops(
        phase: Double,
        palette: NotchGlowPalette,
        maxOpacity: Double = 1
    ) -> [Gradient.Stop] {
        (0...samples).map { index in
            let position = Double(index) / Double(samples)
            // 0 at the centre, 1 at either end.
            let distance = abs(position - 0.5) * 2
            let offset = (distance - phase) / band
            let brightness = max(floor, exp(-offset * offset))
            return Gradient.Stop(
                color: palette.color(atDistance: distance).opacity(brightness * maxOpacity),
                location: position
            )
        }
    }
}

/// The notification signal: a thin neon strip along the notch's outline, pulsing
/// from the centre out to both ends and back.
///
/// ## How it is drawn
///
/// The strip is the notch's own outline, stroked. It lives in the aura window,
/// *behind* the notch, and the stroke is deliberately about twice as wide as the
/// visible result: the panel's own black covers the inner half, so the occlusion
/// does the masking and what remains is a strip hugging the edge from outside.
/// Nothing has to be clipped by hand, and the light can never spill over the
/// content of the panel.
///
/// ## How it moves
///
/// Brightness is a function of horizontal position — a Gaussian band centred at
/// `distance == phase` — so one gradient with sampled stops draws both travelling
/// bands at once, and no animation has to be kept in sync with anything. A dim
/// floor keeps the whole outline faintly lit, so it reads as a strip that has
/// light running through it rather than as two dots chasing each other.
struct NotchGlowView: View {
    var palette: NotchGlowPalette
    /// Corner radius of the shape being traced; the notch's changes when it opens.
    var bottomCornerRadius: CGFloat
    /// Horizontal room the aura window leaves around the notch.
    var horizontalMargin: CGFloat
    /// Room below it.
    var bottomMargin: CGFloat
    /// Fixed phase, for rendering a filmstrip. Nil means "animate".
    var fixedPhase: Double?

    var body: some View {
        if let fixedPhase {
            strip(phase: fixedPhase)
        } else {
            TimelineView(.animation) { context in
                strip(phase: GlowBand.phase(at: context.date))
            }
        }
    }

    private func strip(phase: Double) -> some View {
        let gradient = LinearGradient(
            stops: GlowBand.stops(phase: phase, palette: palette),
            startPoint: .leading,
            endPoint: .trailing
        )
        let shape = NotchShape(
            topFlareRadius: NotchGeometry.flareRadius,
            bottomCornerRadius: bottomCornerRadius
        )

        return ZStack {
            // Bloom first, core over it: the halo is what makes it read as light
            // rather than as a drawn border.
            shape.stroke(gradient, lineWidth: 11).blur(radius: 7).opacity(0.75)
            shape.stroke(gradient, lineWidth: 5.5).blur(radius: 1.6)
            shape.stroke(gradient, lineWidth: 3).blur(radius: 0.4)
        }
        // The shape is the notch's, so it has to sit exactly where the notch is:
        // hanging from the top of the window, inside the margins.
        .padding(.horizontal, horizontalMargin)
        .padding(.bottom, bottomMargin)
        .allowsHitTesting(false)
    }

}

/// Renders the glow to PNGs, one per phase.
///
/// The signal is an animation on a window above the menu bar, so it cannot be
/// checked from the code and `screencapture` needs the Screen Recording
/// permission this machine does not grant. Each frame is composed the way the real
/// thing is layered — background, glow, then the panel's black over it — so what
/// the file shows is what the strip will look like, occlusion included.
@MainActor
enum NotchGlowFilmstrip {
    static func write(
        to directory: URL,
        notchSize: CGSize,
        bottomCornerRadius: CGFloat,
        palette: NotchGlowPalette,
        phases: [Double],
        name: String
    ) {
        let margin = NotchAuraWindow.margin
        for (index, phase) in phases.enumerated() {
            let frame = ZStack {
                // Stand-in for what is behind: a wallpaper, and the lighter strip
                // of the menu bar across the top.
                LinearGradient(
                    colors: [Color(white: 0.42), Color(white: 0.16)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(spacing: 0) {
                    Color.white.opacity(0.10).frame(height: 32)
                    Spacer(minLength: 0)
                }

                NotchGlowView(
                    palette: palette,
                    bottomCornerRadius: bottomCornerRadius,
                    horizontalMargin: margin,
                    bottomMargin: margin,
                    fixedPhase: phase
                )

                // The panel itself, which is what hides the inner half of the stroke.
                VStack(spacing: 0) {
                    NotchShape(
                        topFlareRadius: NotchGeometry.flareRadius,
                        bottomCornerRadius: bottomCornerRadius
                    )
                    .fill(Color.black)
                    .frame(width: notchSize.width, height: notchSize.height)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: notchSize.width + margin * 2, height: notchSize.height + margin)

            let renderer = ImageRenderer(content: frame)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:])
            else { continue }

            let url = directory.appendingPathComponent("glow-\(name)-\(index).png")
            try? data.write(to: url)
        }
        Log.info("Filmstrip glow «\(name)» scritto in \(directory.path)", category: .panel)
    }
}
