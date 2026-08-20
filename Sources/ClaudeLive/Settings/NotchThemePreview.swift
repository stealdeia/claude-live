import SwiftUI
import ClaudeLiveKit

/// Come sarà il pannello aperto, in piccolo.
///
/// Esiste perché un campione di colore da un centimetro non dice niente di utile:
/// il gradiente di questo pannello si legge solo su un'altezza vera — è nero in
/// cima per confondersi col ritaglio, e il colore arriva scendendo. Scegliere un
/// tema da quattro quadratini vuol dire scegliere alla cieca la cosa che conta.
///
/// Le proporzioni sono quelle del pannello reale, ridotte: 624×243 con la
/// striscia da 32. Il contenuto è schematico di proposito — l'anteprima riguarda
/// il colore, e riempirla di testo finto farebbe leggere quello invece del tema.
struct NotchThemePreview: View {
    let theme: ColorTheme

    private let width: CGFloat = 330
    private var height: CGFloat { width * 243 / 624 }
    private var barHeight: CGFloat { height * 32 / 243 }

    private var shape: NotchShape {
        NotchShape(
            topFlareRadius: NotchGeometry.flareRadius,
            bottomCornerRadius: NotchGeometry.expandedCornerRadius
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            shape.fill(theme.panelWash(blackUntil: barHeight / height))
            content
        }
        .frame(width: width, height: height)
        // Ritagliato sulla forma: senza, il contenuto schematico esce dagli angoli
        // arrotondati e l'anteprima non somiglia più al pannello.
        .clipShape(shape)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            // La striscia, con i due anelli ai lati del ritaglio.
            HStack {
                ring(GlowRGB.waiting.color)
                Spacer()
                ring(GlowRGB.done.color)
            }
            .padding(.horizontal, 26)
            .frame(height: barHeight)

            meter(label: 0.30, fill: 0.24, colour: GlowRGB.waiting.color)
            meter(label: 0.38, fill: 0.58, colour: GlowRGB.done.color)

            HStack(spacing: 6) {
                Circle()
                    .fill(GlowRGB.done.color)
                    .frame(width: 5, height: 5)
                Capsule()
                    .fill(.white.opacity(0.26))
                    .frame(width: width * 0.26, height: 5)
            }
            .padding(.top, 1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private func ring(_ colour: Color) -> some View {
        Circle()
            .strokeBorder(colour, lineWidth: 2)
            .frame(width: 11, height: 11)
    }

    private func meter(label: CGFloat, fill: CGFloat, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Capsule()
                .fill(.white.opacity(0.30))
                .frame(width: width * label, height: 5)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10))
                Capsule().fill(colour).frame(width: (width - 36) * fill)
            }
            .frame(height: 4)
        }
    }
}
