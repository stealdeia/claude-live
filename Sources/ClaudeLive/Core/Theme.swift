import AppKit
import SwiftUI

/// Which surface the app shows its content on.
enum DisplayMode: String, Codable, CaseIterable, Identifiable {
    /// The draggable floating panel.
    case floating
    /// Strips flanking the physical notch, expanding downward on demand.
    case notch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .floating: return "Pannello flottante"
        case .notch: return "Notch"
        }
    }
}

/// Which displays get a notch surface.
///
/// Separate from the list of chosen screens so that unplugging the chosen monitor
/// is recoverable: the selection stays on disk and comes back when it does.
enum NotchScreenSelection: String, Codable, CaseIterable, Identifiable {
    /// The screen with a physical cutout; the main screen if none has one.
    case automatic
    /// Only the displays the user ticked.
    case chosen
    /// Every connected display.
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatico"
        case .chosen: return "Schermi scelti"
        case .all: return "Tutti gli schermi"
        }
    }
}

/// Size of one notch bar's middle section, as stored per screen.
///
/// A plain struct rather than a `CGSize` because it has to round-trip through JSON
/// in the settings file, keyed by display identifier.
struct NotchSize: Codable, Equatable, Sendable {
    var width: Double
    var height: Double

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    init(_ size: CGSize) {
        self.init(width: size.width, height: size.height)
    }

    var cgSize: CGSize { CGSize(width: width, height: height) }
}

/// Appearance for the floating panel. The notch surface ignores this and is
/// always black — it has to match the physical notch it grows out of.
enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Come il sistema"
        case .light: return "Chiaro"
        case .dark: return "Scuro"
        }
    }

    /// Set on the *window* rather than via SwiftUI's `.colorScheme`, because
    /// `NSVisualEffectView` picks its material from the window's appearance and
    /// would otherwise stay light inside a dark view tree. SwiftUI inherits the
    /// window appearance, so one assignment covers both layers.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// How a surface paints behind its content.
enum SurfaceStyle {
    /// Translucent system material; follows the window appearance.
    case material
    /// Opaque black, for the notch: any translucency would break the illusion
    /// of the panel being an extension of the notch itself.
    case solidBlack
}
