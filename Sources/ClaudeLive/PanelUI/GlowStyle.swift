import SwiftUI
import ClaudeLiveKit

/// How one kind of alert lights the strip, in a form that can be stored.
///
/// `NotchGlowPalette` is what the view wants — a function from position to colour.
/// This is what `settings.json` can hold: a mode and two colours, with the second
/// ignored unless the mode uses it. Keeping them separate means the drawing code
/// never has to know about optional fields, and the settings file never has to
/// hold a closure.
struct GlowStyle: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case solid, blend, rainbow

        var id: String { rawValue }

        var label: String {
            switch self {
            case .solid: return "Tinta unita"
            case .blend: return "Sfumatura"
            case .rainbow: return "Arcobaleno"
            }
        }
    }

    var mode: Mode = .solid
    /// The colour at the centre of the notch.
    var primary: GlowRGB
    /// The colour at the two ends, used by `blend`.
    var secondary: GlowRGB

    var palette: NotchGlowPalette {
        switch mode {
        case .solid: return .solid(primary)
        case .blend: return .blend(primary, secondary)
        case .rainbow: return .rainbow
        }
    }

    /// The default for a kind: its own colour, fading to a dimmer version of
    /// itself at the ends if the user switches to a blend without picking one.
    static func `default`(for kind: ClaudeAlertKind) -> GlowStyle {
        let color = kind.defaultColor
        return GlowStyle(
            mode: .solid,
            primary: color,
            secondary: GlowRGB.blend(color, GlowRGB(red: 1, green: 1, blue: 1), 0.55)
        )
    }
}
