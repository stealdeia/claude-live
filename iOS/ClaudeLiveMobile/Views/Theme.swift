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
        didSet { remember(theme) }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "themeID")
        theme = ColorTheme.named(saved)
        // Riaffermata all'avvio, non solo quando si cambia: chi aveva già scelto
        // un tema prima che il deposito condiviso esistesse non lo cambierà di
        // nuovo per farlo sapere all'estensione, e senza questa riga vedrebbe
        // widget di un colore e app di un altro per sempre.
        remember(theme)
    }

    /// Scritta in due posti, e non è un doppione.
    ///
    /// `UserDefaults.standard` è un dominio **per bersaglio**: l'estensione ne ha
    /// uno suo, e vuoto. È il motivo per cui la Live Activity ha avuto
    /// `.midnight` scritto a mano fin qui. La seconda copia sta nel dominio del
    /// gruppo condiviso, che l'estensione legge.
    ///
    /// La prima resta perché è dove l'app la cerca all'avvio, e cambiare anche
    /// quella significherebbe che chi aggiorna perde il tema che aveva scelto.
    private func remember(_ theme: ColorTheme) {
        UserDefaults.standard.set(theme.id, forKey: "themeID")
        SharedStore.themeID = theme.id
    }
}
