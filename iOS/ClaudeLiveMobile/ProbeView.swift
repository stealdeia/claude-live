import SwiftUI
import ClaudeLiveKit

/// The whole app: two fields, a button, and the numbers.
///
/// `Format.age` and the glow palette come from `ClaudeLiveKit` — the same code
/// the Mac panel uses. Not decoration: it is the running proof that the shared
/// package compiles and links on iOS, which is the point of having extracted it.
struct ProbeView: View {
    @ObservedObject var probe: RelayProbe

    var body: some View {
        NavigationStack {
            Form {
                Section("Relay") {
                    TextField("https://…workers.dev", text: $probe.relayURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    SecureField("Parola d'ordine", text: $probe.secret)

                    Button("Registra questo iPhone") {
                        Task { await probe.requestPermission() }
                    }
                    .disabled(probe.relayURL.isEmpty || probe.secret.isEmpty)
                }

                Section("Stato") {
                    Text(probe.status)
                        .font(.callout)
                    if let token = probe.deviceToken {
                        LabeledContent("Token") {
                            Text(token.prefix(16) + "…")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }

                Section("Misure") {
                    if probe.measurements.isEmpty {
                        Text("Nessuna ancora. Lancia /ping dal Mac.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(probe.measurements) { measurement in
                            row(for: measurement)
                        }
                    }
                }
            }
            .navigationTitle("Prova di velocità")
        }
    }

    private func row(for measurement: RelayProbe.Measurement) -> some View {
        HStack {
            Circle()
                .fill(colour(for: measurement).color)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(measurement.milliseconds) ms")
                    .font(.system(.body, design: .monospaced))
                Text(caption(for: measurement.arrival))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(Format.age(since: measurement.at))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Green below a second, amber up to five, red past that — the thresholds
    /// that matter for a hook that will not wait forever.
    private func colour(for measurement: RelayProbe.Measurement) -> GlowRGB {
        switch measurement.milliseconds {
        case ..<1_000: return .done
        case ..<5_000: return .waiting
        default: return .failed
        }
    }

    private func caption(for arrival: RelayProbe.Measurement.Arrival) -> String {
        switch arrival {
        case .foreground:
            return "app aperta — solo trasporto"
        case .tapped:
            return "toccata — trasporto più il tempo di accorgersene"
        }
    }
}
