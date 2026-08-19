import SwiftUI
import ClaudeLiveKit

/// The relay connection, and the phase 0 stopwatch.
///
/// Kept after the measurement was taken because it is still the only way to
/// answer "is the phone reachable at all?" without involving the Mac — the
/// first question worth asking when nothing arrives.
struct ProbeSettings: View {
    @ObservedObject var probe: RelayProbe

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Collegamento")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 10) {
                TextField("https://…workers.dev", text: $probe.relayURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(10)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))

                SecureField("Parola d'ordine", text: $probe.secret)
                    .padding(10)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }

            Button {
                Task { await probe.requestPermission() }
            } label: {
                Text("Registra questo iPhone").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(probe.relayURL.isEmpty || probe.secret.isEmpty)

            Text(probe.status)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))

            if !probe.measurements.isEmpty {
                Divider().overlay(.white.opacity(0.15))
                Text("Prove di velocità")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))

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
