import SwiftUI
import ClaudeLiveKit

/// Il segnale luminoso attorno allo schermo, quando c'è un avviso da vedere.
///
/// ## Come si muove
///
/// La luce parte dal centro in alto — dove sul telefono c'è l'isola dinamica, e
/// dove sul Mac c'è il notch — scende lungo i due lati fino al centro in basso, e
/// torna. Il resto del contorno resta debolmente accesso, così si legge come una
/// striscia in cui scorre della luce e non come due punti che si inseguono.
///
/// Non è una somiglianza: la luminosità lungo il giro viene da `GlowBand.stops`,
/// la stessa funzione che disegna la striscia attorno al notch. Un evento, un
/// ritmo, su qualunque schermo venga riferito.
///
/// La prima versione pulsava e basta — l'intera cornice che si accendeva e
/// spegneva insieme — perché avevo usato solo la fase e buttato via la banda.
/// Era anche cinque volte più spessa: un tratto da 26 punti al posto dei tre
/// sovrapposti che rendono il Mac delicato.
///
/// ## Come è disegnata
///
/// Tre tratti uno sull'altro, con le larghezze e le sfocature del Mac: l'alone
/// larghissimo è quello che la fa leggere come *luce* invece che come un bordo
/// disegnato, e il tratto nitido al centro le dà il filo. Il tracciato coincide
/// con lo schermo, quindi metà dello spessore cade fuori e viene tagliato: la
/// striscia abbraccia il bordo invece di galleggiarci dentro, che è lo stesso
/// trucco con cui sul Mac il pannello nero copre la metà interna.
struct AppGlow: View {
    let style: GlowStyle

    /// Fase fissa, per mostrarne un fotogramma fermo. `nil` significa «animala».
    var fixedPhase: Double?

    var body: some View {
        if let fixedPhase {
            ring(phase: fixedPhase)
        } else {
            TimelineView(.animation) { timeline in
                ring(phase: GlowBand.phase(at: timeline.date))
            }
        }
    }

    private func ring(phase: Double) -> some View {
        // Il giro parte dal basso, così la metà del gradiente — dove la banda ha
        // distanza zero — cade in cima allo schermo. Le stesse fermate del Mac,
        // senza toccarle: là scorrono da sinistra a destra, qui attorno.
        let gradient = AngularGradient(
            stops: GlowBand.stops(phase: phase, palette: style.palette),
            center: .center,
            startAngle: .degrees(90),
            endAngle: .degrees(450)
        )
        let shape = RoundedRectangle(cornerRadius: Self.screenCornerRadius, style: .continuous)

        return ZStack {
            // Alone prima, filo sopra: le stesse tre larghezze e le stesse tre
            // sfocature della striscia attorno al notch, prese di peso e non
            // riadattate. Le avevo raddoppiate ragionando che uno schermo è più
            // grande di un notch — vero, ma la richiesta era «delicato come nel
            // notch del mac», e fra sbagliare in grosso e sbagliare in sottile
            // il secondo si corregge guardando, il primo dà fastidio.
            shape.stroke(gradient, lineWidth: 11).blur(radius: 7).opacity(0.75)
            shape.stroke(gradient, lineWidth: 5.5).blur(radius: 1.6)
            shape.stroke(gradient, lineWidth: 3).blur(radius: 0.4)
        }
        .ignoresSafeArea()
        // Non intercetta i tocchi: è un segnale, non un pulsante, e coprire lo
        // schermo con qualcosa da toccare renderebbe l'app inutilizzabile proprio
        // quando c'è qualcosa da fare.
        .allowsHitTesting(false)
    }

    /// Il raggio degli angoli dello schermo.
    ///
    /// Un valore fisso: quello vero non è esposto da nessuna interfaccia
    /// pubblica, e i telefoni con l'isola dinamica stanno tutti attorno a questo.
    /// Sbagliarlo di qualche punto non si vede, perché sopra il tracciato passa
    /// un alone sfocato di sette.
    private static let screenCornerRadius: CGFloat = 55
}

/// La stessa pulsazione, applicata a una riga: il progetto interessato.
///
/// Serve a rispondere alla domanda a cui la cornice non risponde — *quale* — ed è
/// il motivo per cui sul Mac la riga del progetto si illumina insieme alla
/// striscia. Qui pulsa senza scorrere, come là: su una riga alta cinquanta punti
/// una luce che viaggia attirerebbe l'occhio sul movimento invece che sul nome.
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
                            .fill(style.palette.color(atDistance: 0).opacity(0.08 + 0.18 * phase))
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
