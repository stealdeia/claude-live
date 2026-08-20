import SwiftUI
import VisionKit
import ClaudeLiveKit

/// Pairing: point the camera at the code the Mac is showing.
///
/// With a typed fallback, because a camera can be refused, broken, or simply
/// unavailable in the Simulator — and a setup step with exactly one way through
/// is a setup step that can dead-end.
struct PairingView: View {
    @ObservedObject var store: RemoteStore
    @Environment(\.dismiss) private var dismiss

    /// Aperta già inquadrando.
    ///
    /// Prima mostrava una schermata con un bottone per iniziare a inquadrare:
    /// due tocchi per una cosa che si è già scelta di fare, dato che qui si
    /// arriva premendo «Inquadra il codice». La schermata sotto resta, e si vede
    /// chiudendo la fotocamera o se la scansione non riesce — dove serve, perché
    /// contiene la strada alternativa.
    @State private var scanning = true
    @State private var manualPayload = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                ThemedBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Sul Mac apri Impostazioni → iPhone e premi «Mostra il QR».")
                                    .font(.footnote)
                                    .foregroundStyle(.white.opacity(0.8))

                                Button {
                                    scanning = true
                                } label: {
                                    Label("Inquadra il codice", systemImage: "qrcode.viewfinder")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!DataScannerViewController.isSupported)

                                if !DataScannerViewController.isSupported {
                                    Text("La fotocamera non è disponibile qui: usa l'incollaggio manuale.")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Oppure incolla il codice")
                                    .font(.subheadline.weight(.semibold))
                                TextField("{\"url\":…}", text: $manualPayload, axis: .vertical)
                                    .lineLimit(3...6)
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(10)
                                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                                Button("Accoppia") {
                                    if store.pair(withPayload: manualPayload) { dismiss() } else { failed = true }
                                }
                                .buttonStyle(.bordered)
                                .disabled(manualPayload.isEmpty)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if failed {
                            Text("Codice non valido.")
                                .font(.footnote)
                                .foregroundStyle(GlowRGB.failed.color)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .preferredColorScheme(.dark)
            .navigationTitle("Accoppia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annulla") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $scanning) {
                ScannerView { payload in
                    scanning = false
                    if store.pair(withPayload: payload) { dismiss() } else { failed = true }
                } onCancel: {
                    scanning = false
                }
            }
        }
    }
}

/// The camera, wrapped.
struct ScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            // One code, once. Pairing has a single correct outcome, so there is
            // nothing to choose between and nothing to keep scanning for.
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFound: onFound)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onFound: (String) -> Void
        /// The delegate fires repeatedly for the same code; without this the
        /// pairing would be applied several times over.
        private var handled = false

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !handled else { return }
            for item in addedItems {
                if case let .barcode(barcode) = item, let text = barcode.payloadStringValue {
                    handled = true
                    dataScanner.stopScanning()
                    onFound(text)
                    return
                }
            }
        }
    }
}
