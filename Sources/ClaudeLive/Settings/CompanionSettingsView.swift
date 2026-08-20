import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import ClaudeLiveKit

/// The iPhone companion's settings: the switch that lets data leave the machine,
/// where it goes, and the QR code that pairs the phone.
///
/// The switch is off until somebody turns it on, and the section says plainly
/// what turning it on means. Everything else this app does happens locally, so
/// this is the one place where that stops being true.
struct CompanionSettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var remote: RemotePublisher

    @State private var showingQR = false
    @State private var confirmingReset = false

    var body: some View {
        Section("iPhone") {
            Toggle("Pubblica sul relay", isOn: $settings.remoteEnabled)
                .help("Finché è spento, nessun dato lascia questo Mac.")

            if settings.remoteEnabled {
                // The hint goes inside the field as a prompt. Passed as a
                // TextField label it renders *beside* the box on macOS, where it
                // reads as a second label rather than as an example of what to
                // type — which is how an address ended up saved without its
                // scheme.
                TextField(
                    "Indirizzo",
                    text: $settings.remoteRelayURL,
                    prompt: Text("claude-live-relay.esempio.workers.dev")
                )
                .onSubmit { tidyURL() }
                .onChange(of: settings.remoteEnabled) { _, _ in tidyURL() }

                // No password field any more. The relay no longer knows one: each
                // Mac carries its own identifier, made here and shown only in the
                // QR. One field left to fill, and it is an address.
                Button("Salva l'indirizzo") {
                    tidyURL()
                    remote.publishNow()
                }
                .disabled(settings.remoteRelayURL.isEmpty)

                LabeledContent("Stato") {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(stateColour)
                            .frame(width: 8, height: 8)
                        Text(remote.connection.label)
                            .foregroundStyle(.secondary)
                        if let at = remote.lastPublishedAt {
                            Text("· \(Format.age(since: at))")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.callout)
                }

                HStack {
                    Button("Mostra il QR per l'iPhone…") { showingQR = true }
                        .disabled(remote.pairingPayload() == nil)
                    Spacer()
                    Button("Disaccoppia…") { confirmingReset = true }
                        .foregroundStyle(.red)
                }

                Text("La chiave di cifratura viaggia solo nel QR, mai attraverso il relay: è questo che rende il relay incapace di leggere ciò che trasporta.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Spento: lo stato delle sessioni e i limiti di utilizzo restano su questo Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showingQR) {
            PairingQRSheet(payload: remote.pairingPayload() ?? "") { showingQR = false }
        }
        .confirmationDialog(
            "Disaccoppiare l'iPhone?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Disaccoppia", role: .destructive) {
                RemoteSecrets.reset()
                settings.remoteEnabled = false
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Verranno cancellate la parola d'ordine e la chiave. L'app sull'iPhone smetterà di leggere e andrà riaccoppiata con un nuovo QR.")
        }
    }

    /// Writes the address back in the form the publisher will actually use, so
    /// what is on screen is what is in effect. Silently correcting a value while
    /// still showing the old one is how a setting comes to look wrong when it is
    /// right — or the reverse.
    private func tidyURL() {
        guard let tidy = RemotePublisher.normalised(settings.remoteRelayURL) else { return }
        if tidy != settings.remoteRelayURL { settings.remoteRelayURL = tidy }
    }

    private var stateColour: Color {
        switch remote.connection {
        case .publishing: return GlowRGB.done.color
        case .failed: return GlowRGB.failed.color
        case .notConfigured: return GlowRGB.waiting.color
        case .off: return .secondary
        }
    }
}

/// The pairing code, big enough to be read off the screen.
struct PairingQRSheet: View {
    let payload: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Inquadra col telefono")
                .font(.headline)

            if let image = Self.qrImage(from: payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 260, height: 260)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text("Impossibile generare il codice.")
                    .foregroundStyle(.secondary)
            }

            Text("Contiene indirizzo, parola d'ordine e chiave di cifratura. Non fotografarlo e non condividerlo: chi ce l'ha può leggere tutto quello che il Mac pubblica.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)

            Button("Fine", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }

    /// Rendered at the generator's native size and scaled up without smoothing:
    /// interpolating a QR blurs the module edges, which is exactly what a scanner
    /// needs sharp.
    static func qrImage(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // High correction: the code is read off a glossy screen, often at an
        // angle, and the extra redundancy costs only density.
        filter.correctionLevel = "H"

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
