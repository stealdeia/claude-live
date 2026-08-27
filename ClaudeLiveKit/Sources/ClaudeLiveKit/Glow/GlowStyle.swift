import SwiftUI

/// How one kind of alert lights the strip, in a form that can be stored.
///
/// Nel pacchetto condiviso da quando anche l'app per iPhone lascia scegliere i
/// colori del segnale: le due app devono offrire le stesse scelte, e due copie
/// di questo tipo divergerebbero alla prima aggiunta di una modalità.
///
/// `NotchGlowPalette` is what the view wants — a function from position to colour.
/// This is what `settings.json` can hold: a mode and two colours, with the second
/// ignored unless the mode uses it. Keeping them separate means the drawing code
/// never has to know about optional fields, and the settings file never has to
/// hold a closure.
public struct GlowStyle: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case solid, blend, rainbow

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .solid: return "Tinta unita"
            case .blend: return "Sfumatura"
            case .rainbow: return "Arcobaleno"
            }
        }
    }

    public var mode: Mode = .solid
    /// The colour at the centre of the notch.
    public var primary: GlowRGB
    /// The colour at the two ends, used by `blend`.
    public var secondary: GlowRGB

    /// Scritto a mano perché un tipo pubblico tiene il costruttore per membri solo
    /// dentro il proprio modulo, e questo serve alle due app.
    public init(mode: Mode = .solid, primary: GlowRGB, secondary: GlowRGB) {
        self.mode = mode
        self.primary = primary
        self.secondary = secondary
    }

    public var palette: NotchGlowPalette {
        switch mode {
        case .solid: return .solid(primary)
        case .blend: return .blend(primary, secondary)
        case .rainbow: return .rainbow
        }
    }

    /// The default for a kind: its own colour, fading to a dimmer version of
    /// itself at the ends if the user switches to a blend without picking one.
    public static func `default`(for kind: ClaudeAlertKind) -> GlowStyle {
        let color = kind.defaultColor
        return GlowStyle(
            mode: .solid,
            primary: color,
            secondary: GlowRGB.blend(color, GlowRGB(red: 1, green: 1, blue: 1), 0.55)
        )
    }
}
