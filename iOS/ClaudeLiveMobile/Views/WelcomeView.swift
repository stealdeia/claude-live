import SwiftUI
import ClaudeLiveKit

/// La prima schermata, finché non c'è un Mac accoppiato.
///
/// Prende il posto delle tre schede piene di dati d'esempio. L'esempio serviva a
/// giudicare un disegno quando il Mac non poteva ancora pubblicare — un disegno
/// si valuta contro del contenuto — ma da quando pubblica quello stesso esempio
/// è un'app che mostra numeri inventati a chi la apre per la prima volta. Per
/// uno strumento il cui unico scopo è dire cosa sta succedendo davvero, è il
/// difetto peggiore che potesse avere.
///
/// Un passo per schermata, non un elenco. Chi legge ha il telefono in una mano e
/// sta guardando il Mac: un elenco di cinque punti obbliga a tenere il segno
/// mentalmente mentre si guarda altrove, e un passo per volta con «Ho fatto»
/// tiene il segno al posto suo. I comandi sono nominati con le parole che stanno
/// scritte sopra, perché sono quelle che deve cercare sullo schermo.
struct WelcomeView: View {
    let onPair: () -> Void
    let onOpenSettings: () -> Void

    @State private var step = 0

    private struct Page {
        let icon: String
        let title: String
        let text: String
        /// I nomi dei comandi, messi in evidenza dentro la frase.
        var emphasis: [String] = []
        let action: String
    }

    /// I passi sono tre e non cinque perché l'indirizzo del relay è già
    /// nell'app: chiederlo era il passo che rendeva tutto questo indistribuibile.
    private let pages: [Page] = [
        Page(
            icon: "sparkles",
            title: "Claude Live",
            text: "Guarda da qui cosa sta facendo Claude Code sul tuo Mac, e rispondi ai permessi senza tornare alla scrivania.\n\nPer cominciare serve accoppiare il telefono al Mac: tre passaggi.",
            action: "Iniziamo"
        ),
        Page(
            icon: "menubar.arrow.up.rectangle",
            title: "Sul Mac",
            text: "Apri Claude Live dall'icona nella barra dei menu, in alto a destra, e scegli Impostazioni.",
            emphasis: ["Impostazioni"],
            action: "Ho fatto"
        ),
        Page(
            icon: "iphone",
            title: "Accendi la pubblicazione",
            text: "Nelle impostazioni vai alla scheda iPhone e accendi Pubblica sul relay. Finché è spenta, nessun dato lascia il Mac.",
            emphasis: ["iPhone", "Pubblica sul relay"],
            action: "Ho fatto"
        ),
        Page(
            icon: "qrcode",
            title: "Mostra il codice",
            text: "Premi Mostra il QR per l'iPhone. Sullo schermo del Mac compare un codice quadrato.",
            emphasis: ["Mostra il QR per l'iPhone"],
            action: "Ho fatto"
        ),
        Page(
            icon: "qrcode.viewfinder",
            title: "Inquadra",
            text: "Punta la fotocamera del telefono sul codice che vedi sullo schermo del Mac.",
            action: "Inquadra il codice"
        ),
    ]

    private var page: Page { pages[min(step, pages.count - 1)] }
    private var isLast: Bool { step == pages.count - 1 }

    var body: some View {
        ZStack {
            ThemedBackground()

            VStack(spacing: 0) {
                Spacer(minLength: 12)

                GlassCard {
                    VStack(spacing: 16) {
                        Image(systemName: page.icon)
                            .font(.system(size: 34))
                            .foregroundStyle(GlowRGB.waiting.color)
                        Text(page.title)
                            .font(.title3.weight(.semibold))
                        Text(highlighted(page))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if step == 0 { privacy }
                    }
                    .frame(maxWidth: .infinity)
                }
                // Ridisegnata a ogni passo, così la dissolvenza riguarda il
                // contenuto e non la cornice.
                .id(step)
                .transition(.opacity)

                Spacer(minLength: 12)

                controls
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 26)
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            // I passi, non una percentuale: dice quanti sono e dove sei, che è
            // l'unica cosa che serve sapere.
            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? GlowRGB.waiting.color : Color.white.opacity(0.18))
                        .frame(width: index == step ? 18 : 6, height: 6)
                }
            }
            .animation(.easeOut(duration: 0.18), value: step)

            Button {
                if isLast {
                    onPair()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { step += 1 }
                }
            } label: {
                Label(page.action, systemImage: isLast ? "qrcode.viewfinder" : "arrow.right")
                    .labelStyle(TrailingIconLabel())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)

            HStack {
                if step > 0 {
                    Button("Indietro") {
                        withAnimation(.easeOut(duration: 0.2)) { step -= 1 }
                    }
                }
                Spacer()
                Button("Impostazioni", action: onOpenSettings)
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var privacy: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
            Text("Quello che il Mac pubblica è cifrato, e la chiave per aprirlo viaggia solo nel codice QR: il relay trasporta senza poter leggere.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    /// Mette in evidenza i nomi dei comandi dentro la frase.
    ///
    /// Cercati nel testo invece di comporre la frase a pezzi: una frase scritta a
    /// segmenti si rompe alla prima riscrittura, e queste frasi cambieranno ogni
    /// volta che cambia un bottone sul Mac.
    private func highlighted(_ page: Page) -> AttributedString {
        var text = AttributedString(page.text)
        for word in page.emphasis {
            if let range = text.range(of: word) {
                text[range].font = .subheadline.weight(.semibold)
                text[range].foregroundColor = .white
            }
        }
        return text
    }
}

#Preview("Benvenuto") {
    WelcomeView(onPair: {}, onOpenSettings: {})
        .preferredColorScheme(.dark)
}
