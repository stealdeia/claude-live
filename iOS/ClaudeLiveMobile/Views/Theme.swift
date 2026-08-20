import SwiftUI
import ClaudeLiveKit

// MARK: - Distribuzione ai discendenti

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = ColorTheme.midnight
}

extension EnvironmentValues {
    var theme: ColorTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// The chosen theme, remembered between launches.
@Observable
final class ThemeStore {
    var theme: ColorTheme {
        didSet { UserDefaults.standard.set(theme.id, forKey: "themeID") }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "themeID")
        theme = ColorTheme.all.first { $0.id == saved } ?? .midnight
    }
}
