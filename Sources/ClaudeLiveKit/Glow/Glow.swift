import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// A colour for the glow, stored as components rather than as a `Color`.
///
/// `Color` is not `Codable` and cannot be interpolated, and both are needed: the
/// user's choice has to survive in `settings.json`, and a blend has to be computed
/// between two of them.
public struct GlowRGB: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// Spelled out because declaring any other initialiser removes the memberwise
    /// one the rest of the file relies on.
    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    #if canImport(AppKit)
    /// From a `Color`, for the colour pickers in Settings.
    ///
    /// Converted through sRGB explicitly: a colour coming out of the system picker
    /// can be in any colour space, and reading components from it without converting
    /// returns nil for the ones that are not RGB — a silent fall back to black.
    ///
    /// macOS only: it exists for the Settings pickers, and the mobile app has no
    /// colour picker. Writing an untested UIKit conversion would be worse than not
    /// offering one.
    public init(_ color: Color) {
        let native = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(
            red: Double(native.redComponent),
            green: Double(native.greenComponent),
            blue: Double(native.blueComponent)
        )
    }
    #endif

    public static func blend(_ a: GlowRGB, _ b: GlowRGB, _ t: Double) -> GlowRGB {
        let t = t.clamped(to: 0...1)
        return GlowRGB(
            red: a.red + (b.red - a.red) * t,
            green: a.green + (b.green - a.green) * t,
            blue: a.blue + (b.blue - a.blue) * t
        )
    }

    /// Defaults, one per kind of event the glow reports.
    public static let done = GlowRGB(red: 0.24, green: 0.85, blue: 0.45)
    public static let waiting = GlowRGB(red: 1.00, green: 0.72, blue: 0.16)
    public static let failed = GlowRGB(red: 1.00, green: 0.29, blue: 0.28)
}

/// How the strip is coloured along its length.
///
/// Always symmetric around the centre, because the light itself is: it leaves the
/// middle towards both ends at once, so a colour that ran left-to-right would put
/// a different one under each of the two travelling bands.
public enum NotchGlowPalette: Equatable, Sendable {
    /// One colour everywhere.
    case solid(GlowRGB)
    /// From the centre outwards.
    case blend(GlowRGB, GlowRGB)
    case rainbow

    /// `distance` is 0 at the centre of the notch and 1 at either end.
    public func color(atDistance distance: Double) -> Color {
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
///
/// On iOS the same band drives the Live Activity, for the same reason: one event,
/// one rhythm, wherever it is being reported.
public enum GlowBand {
    /// Half-width of the lit band, as a fraction of the half-length.
    public static let band: Double = 0.34
    /// How lit the rest stays, so it reads as a strip with light running through it
    /// rather than as two dots chasing each other.
    public static let floor: Double = 0.16
    /// Enough samples that the band's edges are smooth; the cost is one gradient
    /// either way.
    public static let samples = 48

    /// One full out-and-back. Slow enough to read as breathing rather than as a
    /// warning light.
    public static let period: TimeInterval = 2.6

    /// Out-and-back, eased at both ends so the light lingers at the centre and at
    /// the tips instead of snapping around.
    public static func phase(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        let triangle = t < 0.5 ? t * 2 : (1 - t) * 2
        return triangle * triangle * (3 - 2 * triangle)
    }

    /// Brightness is a function of horizontal position — a Gaussian band centred at
    /// `distance == phase` — so one gradient draws both travelling bands at once and
    /// the symmetry costs nothing.
    public static func stops(
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
