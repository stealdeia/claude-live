import SwiftUI
import ClaudeLiveKit

/// Se e come il telefono si illumina quando arriva un avviso.
///
/// Le stesse scelte dell'app per Mac — accesa o spenta, e per ciascuno dei tre
/// avvisi una modalità e i suoi colori — perché è la stessa cosa vista su due
/// schermi, e trovare due insiemi di opzioni diversi per la stessa funzione è
/// peggio che non averle.
///
/// Locali a questo telefono, come il tema: sono una preferenza di chi guarda,
/// non un fatto sul Mac, e mandarle al relay vorrebbe dire farle decidere a chi
/// non le sta guardando.
@MainActor
final class GlowSettings: ObservableObject {
    @Published var enabled: Bool { didSet { save() } }

    /// Stile per tipo di avviso, con dentro **solo** ciò che è stato cambiato.
    ///
    /// Uno stile che *è* quello predefinito viene rimosso invece di scritto: così
    /// «Ripristina» riporta le cose come erano prima della prima modifica, e non
    /// lascia una copia dei valori predefiniti che sopravviverebbe a un
    /// cambiamento dei predefiniti. È la stessa regola del Mac.
    @Published private(set) var styles: [String: GlowStyle] = [:] { didSet { save() } }

    private let defaults = UserDefaults.standard
    private enum Key {
        static let enabled = "glow.enabled"
        static let styles = "glow.styles"
    }

    init() {
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        if let data = defaults.data(forKey: Key.styles),
           let decoded = try? JSONDecoder().decode([String: GlowStyle].self, from: data) {
            styles = decoded
        }
    }

    func style(for kind: ClaudeAlertKind) -> GlowStyle {
        styles[kind.rawValue] ?? .default(for: kind)
    }

    func setStyle(_ style: GlowStyle, for kind: ClaudeAlertKind) {
        if style == .default(for: kind) {
            styles.removeValue(forKey: kind.rawValue)
        } else {
            styles[kind.rawValue] = style
        }
    }

    func isDefault(_ kind: ClaudeAlertKind) -> Bool {
        styles[kind.rawValue] == nil
    }

    private func save() {
        defaults.set(enabled, forKey: Key.enabled)
        if let data = try? JSONEncoder().encode(styles) {
            defaults.set(data, forKey: Key.styles)
        }
    }
}

/// Quale avviso il telefono sta mostrando, e quali ha già mostrato.
///
/// Separato dalle preferenze perché non è una preferenza: è lo stato di «questo
/// l'ho visto». Vive solo in memoria, e va bene così — un avviso già spento che
/// tornasse dopo un riavvio dell'app durerebbe pochi secondi, mentre ricordarlo
/// su disco vorrebbe dire ricordare per sempre avvisi che non esistono più.
@MainActor
final class GlowState: ObservableObject {
    /// L'avviso già visto, riconosciuto per progetto e tipo.
    ///
    /// Non per oggetto intero: `raisedAt` cambia se il Mac lo ripubblica, e un
    /// avviso identico con un istante diverso tornerebbe ad accendersi da solo.
    @Published private(set) var dismissed: Set<String> = []

    func key(_ alert: ClaudeAlert) -> String {
        "\(alert.kind.rawValue)#\(alert.projectPath)#\(alert.sessionID ?? "")"
    }

    func isLit(_ alert: ClaudeAlert?) -> Bool {
        guard let alert else { return false }
        return !dismissed.contains(key(alert))
    }

    /// Spegne l'avviso di questa chat, se ce n'è uno.
    ///
    /// Chiamato entrando: aprire la chat *è* la presa in carico, e chiedere anche
    /// di premere qualcosa per spegnere la luce sarebbe un secondo gesto per la
    /// stessa decisione.
    func seen(sessionID: String?, projectPath: String, alert: ClaudeAlert?) {
        guard let alert, alert.projectPath == projectPath else { return }
        if let sessionID, let alertSession = alert.sessionID, alertSession != sessionID { return }
        dismissed.insert(key(alert))
    }
}

/// L'avviso in corso, reso raggiungibile da qualunque vista.
///
/// Esiste per una ragione sola: la scheda della chat deve poter spegnere il
/// segnale entrando, e per farlo deve sapere *quale* avviso è in corso. La
/// fotografia non arriva fino a lì, e passarla attraverso tre livelli di viste
/// per un campo solo sarebbe una firma più lunga della funzione.
@MainActor
final class CurrentAlert: ObservableObject {
    @Published var alert: ClaudeAlert?
}
