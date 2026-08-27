import SwiftUI
import ClaudeLiveKit

/// Il segnale luminoso attorno allo schermo, quando c'è un avviso da vedere.
///
/// Lo stesso respiro del Mac, e non per somiglianza: il ritmo viene da
/// `GlowBand`, nel pacchetto condiviso, che è lo stesso codice che fa pulsare la
/// striscia attorno al notch. Un evento, un ritmo, su qualunque schermo venga
/// riferito — due animazioni indipendenti sullo stesso fatto lo farebbero
/// sembrare due fatti.
///
/// Pulsa e non scorre: la luce che passava da un lato all'altro attirava l'occhio
/// sul movimento invece che sulla cosa (Stefano, sul Mac, il 2026-08-21). Attorno
/// a uno schermo intero sarebbe peggio.
struct AppGlow: View {
    let style: GlowStyle

    /// Quanto la luce arriva verso il centro. Sottile: è una cornice, non un velo.
    private let thickness: CGFloat = 26

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = GlowBand.phase(at: timeline.date)
            // Da un respiro appena percettibile a pieno: il minimo non è zero,
            // altrimenti a ogni giro la cornice sparisce e riappare, che si legge
            // come un lampeggio invece di un respiro.
            let intensity = 0.35 + 0.65 * phase

            ZStack {
                border(opacity: intensity)
                    .blur(radius: 18)
                border(opacity: intensity * 0.9)
                    .blur(radius: 6)
            }
            .ignoresSafeArea()
            // Non intercetta i tocchi: è un segnale, non un pulsante, e coprire
            // lo schermo con qualcosa da toccare renderebbe l'app inutilizzabile
            // proprio quando c'è qualcosa da fare.
            .allowsHitTesting(false)
        }
    }

    private func border(opacity: Double) -> some View {
        // Il gradiente angolare gira attorno allo schermo prendendo i colori
        // dalla stessa tavolozza del Mac, così «Arcobaleno» e «Sfumatura» qui
        // significano esattamente quello che significano là.
        RoundedRectangle(cornerRadius: 52, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    stops: ringStops(opacity: opacity),
                    center: .center
                ),
                lineWidth: thickness
            )
    }

    /// I colori lungo il giro.
    ///
    /// La tavolozza condivisa è una funzione della *distanza dal centro* — pensata
    /// per una striscia — e qui la distanza diventa la posizione lungo il
    /// perimetro, andata e ritorno: così una sfumatura resta simmetrica invece di
    /// avere una cucitura dove il giro si chiude.
    private func ringStops(opacity: Double) -> [Gradient.Stop] {
        let samples = 32
        return (0...samples).map { index in
            let position = Double(index) / Double(samples)
            let distance = position < 0.5 ? position * 2 : (1 - position) * 2
            return Gradient.Stop(
                color: style.palette.color(atDistance: distance).opacity(opacity),
                location: position
            )
        }
    }
}

/// La stessa pulsazione, applicata a una riga: il progetto interessato.
///
/// Serve a rispondere alla domanda che la cornice non risponde — *quale* — ed è
/// il motivo per cui sul Mac la riga del progetto si illumina insieme alla
/// striscia.
struct GlowingRow: ViewModifier {
    let style: GlowStyle
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation) { timeline in
                let phase = GlowBand.phase(at: timeline.date)
                content
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(style.palette.color(atDistance: 0).opacity(0.10 + 0.22 * phase))
                            .padding(.horizontal, -8)
                            .padding(.vertical, -5)
                    )
            }
        } else {
            content
        }
    }
}

extension View {
    /// Fa pulsare questa riga come pulsa la cornice.
    func glowingRow(style: GlowStyle, active: Bool) -> some View {
        modifier(GlowingRow(style: style, active: active))
    }
}

#Preview("Segnale") {
    ZStack {
        ThemedBackground()
        VStack(spacing: 20) {
            Text("Claude aspetta una risposta")
                .font(.headline)
            Text("sito-claude-live")
                .font(.subheadline)
                .glowingRow(style: .default(for: .waiting), active: true)
        }
        AppGlow(style: .default(for: .waiting))
    }
    .preferredColorScheme(.dark)
}
