import SwiftUI

/// The look of the app, as data.
///
/// A theme is a list of colours and nothing else — no view knows the name of a
/// particular one. That is what makes adding a new one later a matter of one
/// entry in `all`, which is the point: the plan is to hand out new looks over
/// time the way Revolut does with its card skins.
struct AppTheme: Identifiable, Hashable {
    let id: String
    let name: String

    /// The top of the screen. Black on purpose, so the background meets the
    /// Dynamic Island and the two stop being distinguishable — the phone's own
    /// hardware becomes the top edge of the app.
    let top: Color
    /// Where the colour arrives, at the bottom.
    let deep: Color
    /// The bloom in the middle, which is what stops it reading as a plain fade.
    let bloom: Color
    /// For the elements that have to stand out against all of it.
    let accent: Color

    static let midnight = AppTheme(
        id: "midnight",
        name: "Mezzanotte",
        top: Color(red: 0.02, green: 0.02, blue: 0.04),
        deep: Color(red: 0.05, green: 0.11, blue: 0.30),
        bloom: Color(red: 0.09, green: 0.18, blue: 0.42),
        accent: Color(red: 0.38, green: 0.62, blue: 1.00)
    )

    /// The house colour: the project ships under the Purple Heads name.
    static let purpleHeart = AppTheme(
        id: "purpleHeart",
        name: "Purple Heart",
        top: Color(red: 0.03, green: 0.02, blue: 0.05),
        deep: Color(red: 0.20, green: 0.06, blue: 0.34),
        bloom: Color(red: 0.32, green: 0.11, blue: 0.48),
        accent: Color(red: 0.78, green: 0.52, blue: 1.00)
    )

    static let ember = AppTheme(
        id: "ember",
        name: "Brace",
        top: Color(red: 0.04, green: 0.02, blue: 0.02),
        deep: Color(red: 0.30, green: 0.08, blue: 0.05),
        bloom: Color(red: 0.46, green: 0.16, blue: 0.06),
        accent: Color(red: 1.00, green: 0.60, blue: 0.35)
    )

    static let forest = AppTheme(
        id: "forest",
        name: "Bosco",
        top: Color(red: 0.02, green: 0.03, blue: 0.03),
        deep: Color(red: 0.04, green: 0.22, blue: 0.16),
        bloom: Color(red: 0.06, green: 0.32, blue: 0.24),
        accent: Color(red: 0.40, green: 0.92, blue: 0.68)
    )

    static let all: [AppTheme] = [.midnight, .purpleHeart, .ember, .forest]
}

// MARK: - Distribuzione ai discendenti

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.midnight
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// The chosen theme, remembered between launches.
@Observable
final class ThemeStore {
    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.id, forKey: "themeID") }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "themeID")
        theme = AppTheme.all.first { $0.id == saved } ?? .midnight
    }
}
