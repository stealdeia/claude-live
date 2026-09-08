import SwiftUI

/// Come si vede uno stato: un colore e un simbolo.
///
/// ## Perché sta qui e non in una vista
///
/// Lo leggono in tre: l'app, l'isola dinamica e i widget. Finché stava nell'app
/// come estensione privata — `iOS/ClaudeLiveMobile/Views/StatusStyle.swift` — gli
/// altri due se lo riscrivevano a mano, e `ProjectLine` dentro l'isola aveva già
/// la sua copia. La terza copia, quella dei widget, è quella che ha reso il costo
/// evidente: due progetti nello stesso stato devono avere lo stesso colore su
/// qualunque superficie, o si leggono come due cose diverse che succedono insieme.
extension ClaudeActivity {
    /// I colori sono quelli del ritaglio del MacBook — `GlowRGB.waiting`, `.done`,
    /// `.failed` — così un progetto ambra sul Mac è lo stesso ambra sul telefono.
    /// Due dispositivi che riferiscono un solo evento devono concordare sul suo
    /// colore.
    public var tint: Color {
        switch self {
        case .waitingInput: return GlowRGB.waiting.color
        // Verde e non il colore d'accento: «sta lavorando» è la stessa cosa che
        // sul Mac è verde, e l'azzurro del sistema la faceva leggere come una
        // voce selezionata invece che come uno stato.
        case .working: return GlowRGB.done.color
        case .error: return GlowRGB.failed.color
        case .idle: return .secondary
        case .unknown: return .secondary
        }
    }

    /// Il simbolo dello stato, per i posti dove un pallino non basta.
    ///
    /// Non è un ornamento. In StandBy notturno iOS disegna i widget in modalità
    /// `vibrant`, che appiattisce i colori su un'unica tinta: là il pallino
    /// colorato non distingue più niente, e il simbolo è l'unica cosa che resta a
    /// dire se quel progetto sta lavorando o sta aspettando.
    public var symbol: String {
        switch self {
        case .waitingInput: return "bell.badge.fill"
        case .working: return "gearshape.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}
