import SwiftUI
import ClaudeLiveKit

/// How a state looks, in one place.
///
/// The colours are the notch's own — `GlowRGB.waiting`, `.done`, `.failed` — so
/// a project that is amber on the Mac is the same amber here. Two devices
/// reporting one event have to agree on its colour, or they read as two
/// unrelated things happening at once.
extension ClaudeActivity {
    var tint: Color {
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

    /// SF Symbol for the state, for the places a dot is not enough.
    var symbol: String {
        switch self {
        case .waitingInput: return "bell.badge.fill"
        case .working: return "gearshape.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

/// The dot that carries a project's state in a list.
struct StatusDot: View {
    let state: ClaudeActivity
    var isStale: Bool = false
    var size: CGFloat = 10

    /// Se pulsa. I tre stati che chiedono attenzione pulsano, gli altri no: un
    /// pallino fermo accanto a una chat a riposo è un'informazione, uno che pulsa
    /// per niente è rumore che insegna a ignorarlo.
    private var breathes: Bool {
        !isStale && (state == .working || state == .waitingInput || state == .error)
    }

    @State private var phase = false

    var body: some View {
        ZStack {
            // L'alone che respira. Fuori dal cerchio pieno, così il pallino resta
            // della sua dimensione e a muoversi è la luce attorno — come la
            // striscia sul Mac, che pulsa senza cambiare spessore.
            if breathes {
                // Ingrandito, non ridimensionato. La differenza non è di stile.
                //
                // Prima l'alone animava la propria `frame`, che è una proprietà
                // di **impaginazione**: cambiarla sessanta volte al secondo
                // costringe chi disegna a rifare i conti dello spazio a ogni
                // fotogramma. La cornice fissa qui sotto impediva al pallino di
                // spostare i vicini, ma non impediva il ricalcolo — e dentro una
                // lista in uno scorrimento quel ricalcolo arrivava fino alla
                // posizione della vista.
                //
                // È il rimbalzo della chat, misurato: un'onda pulita di periodo
                // 1,3 secondi, cioè esattamente questa animazione, e una ventina
                // di punti di ampiezza. Con `scaleEffect` l'aspetto è identico ma
                // l'ingrandimento avviene al disegno, dopo che lo spazio è già
                // stato deciso: zero impaginazione, zero rimbalzo.
                Circle()
                    .fill(state.tint.opacity(phase ? 0.05 : 0.30))
                    .frame(width: size * 2.6, height: size * 2.6)
                    .scaleEffect(phase ? 1 : 1.6 / 2.6)
            }

            Circle()
                .fill(state.tint)
                .frame(width: size, height: size)
                // A stale record is drawn faded rather than hidden or recoloured:
                // "I am not sure any more" is different from both "fine" and "wrong".
                .opacity(isStale ? 0.4 : 1)
        }
        // Una cornice fissa: senza, l'alone che cresce sposta ciò che gli sta
        // accanto a ogni respiro.
        .frame(width: size * 2.6, height: size * 2.6)
        .onAppear {
            guard breathes else { return }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
        .onChange(of: breathes) { _, now in
            if now {
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                    phase = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { phase = false }
            }
        }
    }
}

#Preview("Pallini") {
    HStack(spacing: 24) {
        ForEach([ClaudeActivity.waitingInput, .working, .error, .idle, .unknown], id: \.self) { state in
            VStack(spacing: 10) {
                StatusDot(state: state, size: 14)
                Text(state.label).font(.caption2)
            }
        }
    }
    .padding(40)
}
