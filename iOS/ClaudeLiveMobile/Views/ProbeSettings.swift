import SwiftUI
import ClaudeLiveKit

/// Il cronometro delle notifiche: quanto ci mette un avviso ad arrivare.
///
/// Sola lettura. Aveva anche i campi per l'indirizzo del relay e una parola
/// d'ordine, da quando andavano scritti a mano per misurare: da quando arrivano
/// col QR erano un doppione che invitava a rompere una cosa che funziona, e
/// l'utente non deve poter scollegare la propria app modificando un campo di cui
/// non capisce lo scopo.
///
/// Non compare finché non c'è niente da mostrare: una sezione vuota è rumore.
struct ProbeSettings: View {
    @ObservedObject var probe: RelayProbe

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !probe.measurements.isEmpty {
                Text("Prove di velocità")
                    .font(.subheadline.weight(.semibold))

                ForEach(probe.measurements.prefix(5)) { measurement in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(colour(for: measurement).color)
                            .frame(width: 7, height: 7)
                        Text("\(measurement.milliseconds) ms")
                            .font(.system(.caption, design: .monospaced))
                        Text(caption(for: measurement.arrival))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colour(for measurement: RelayProbe.Measurement) -> GlowRGB {
        switch measurement.milliseconds {
        case ..<1_000: return .done
        case ..<5_000: return .waiting
        default: return .failed
        }
    }

    private func caption(for arrival: RelayProbe.Measurement.Arrival) -> String {
        switch arrival {
        case .foreground: return "app aperta"
        case .tapped: return "toccata"
        }
    }
}
