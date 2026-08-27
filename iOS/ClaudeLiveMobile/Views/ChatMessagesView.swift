import SwiftUI
import ClaudeLiveKit

/// La conversazione, come in qualsiasi app di messaggi: i fumetti di Claude a
/// sinistra, i tuoi a destra.
///
/// ## Perché si apre in fondo
///
/// Una chat si legge dall'ultimo messaggio, non dal primo: quello che serve
/// sapere è cosa è stato detto *adesso*, e il resto è contesto che si va a
/// cercare risalendo. Aprire in cima obbligherebbe a scorrere fino in fondo ogni
/// volta per arrivare al punto.
///
/// ## Perché il grassetto è grassetto
///
/// Claude scrive in Markdown. Mostrarlo così com'è vuol dire mostrare gli
/// asterischi, e una bolla piena di `**` si legge peggio di una senza enfasi.
/// La resa sta in `MessageMarkdown`, nel pacchetto condiviso, con le sue prove.
struct ChatMessagesView: View {
    let messages: [ClaudeMessage]

    /// Spiegazione da mostrare quando non c'è niente: dire *perché* è vuoto,
    /// perché «niente qui» verrebbe letto come «Claude non ha detto niente»,
    /// che è un fatto diverso.
    let emptyExplanation: String

    /// Ancora dell'ultimo messaggio, per portarci la vista all'apertura.
    private enum Anchor: Hashable { case bottom }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if messages.isEmpty {
                        Text(emptyExplanation)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 20)
                    } else {
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                            bubble(message)
                        }
                    }

                    // Un punto invisibile in fondo, che è l'unico modo affidabile
                    // di dire «qui» a `scrollTo`: l'ultimo messaggio può essere
                    // alto una schermata, e portarsi al suo inizio lascerebbe
                    // fuori proprio la parte nuova.
                    Color.clear
                        .frame(height: 1)
                        .id(Anchor.bottom)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            // Il modo giusto di aprirsi in fondo: deciso *prima* del disegno,
            // quindi non c'è nessun salto da vedere. Chiedere lo scorrimento in
            // `onAppear` funzionava a volte e a volte no — su una lista pigra
            // l'ultimo messaggio può non essere ancora disegnato nel momento in
            // cui glielo si chiede, e allora la richiesta cade nel vuoto.
            .defaultScrollAnchor(.bottom)
            .onAppear { proxy.scrollTo(Anchor.bottom, anchor: .bottom) }
            .onChange(of: messages.count) { _, _ in
                // Un messaggio nuovo mentre si guarda: si scende, come farebbe
                // qualsiasi app di messaggi.
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Anchor.bottom, anchor: .bottom)
                }
            }
        }
    }

    private func bubble(_ message: ClaudeMessage) -> some View {
        MessageBubble(message: message)
    }
}

/// Un fumetto, con il suo «leggi tutto».
///
/// Separato perché ha uno stato suo: se è aperto o chiuso. Il messaggio arriva
/// **intero** dal Mac — quello non si tocca, era il difetto — ma un messaggio di
/// tremila caratteri riempie tre schermate e seppellisce quelli dopo. Quindi si
/// mostra accorciato e si apre toccando.
private struct MessageBubble: View {
    let message: ClaudeMessage

    @State private var expanded = false

    /// Sopra queste righe il fumetto si chiude da sé.
    ///
    /// Dodici e non tre: la soglia serve per i messaggi che sono *documenti*, non
    /// per quelli lunghi. Chiudere qualcosa che si sarebbe letto in un colpo
    /// aggiunge un tocco senza risparmiare niente.
    private let collapsedLines = 12

    /// Sotto questa lunghezza non vale nemmeno la pena contare le righe.
    private var isLong: Bool { message.text.count > 700 }

    var body: some View {
        let mine = message.author == .user
        return HStack(alignment: .bottom, spacing: 0) {
            // I tuoi a destra, quelli di Claude a sinistra: il lato dice chi
            // parla prima che si legga una parola.
            if mine { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 5) {
                Text(MessageMarkdown.attributed(message.text))
                    .font(.footnote)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(expanded || !isLong ? nil : collapsedLines)

                if isLong {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        Text(expanded ? "Riduci" : "Leggi tutto")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }

                if let at = message.at {
                    Text(Format.messageTime(at))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                BubbleShape(pointingRight: mine)
                    .fill(mine ? GlowRGB.done.color.opacity(0.20) : .white.opacity(0.10))
            )

            if !mine { Spacer(minLength: 40) }
        }
    }
}

/// Un fumetto con l'angolo inferiore appuntito sul lato di chi parla.
///
/// Disegnato invece di usare un rettangolo stondato perché è l'unico dettaglio
/// che rende una fila di rettangoli una *conversazione*, e costa dieci righe.
private struct BubbleShape: Shape {
    let pointingRight: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 14
        let corners: UIRectCorner = pointingRight
            ? [.topLeft, .topRight, .bottomLeft]
            : [.topLeft, .topRight, .bottomRight]
        return Path(
            UIBezierPath(
                roundedRect: rect,
                byRoundingCorners: corners,
                cornerRadii: CGSize(width: radius, height: radius)
            ).cgPath
        )
    }
}

#Preview("Conversazione") {
    ZStack {
        ThemedBackground()
        ChatMessagesView(
            messages: [
                ClaudeMessage(
                    author: .user,
                    text: "Sistemami il pannello, i pulsanti non escono.",
                    at: Date().addingTimeInterval(-7200)
                ),
                ClaudeMessage(
                    author: .assistant,
                    text: "## Trovato\nEra una **variabile sovrascritta** in `await_decision`:\n\n- il percorso del progetto veniva perso\n- l'attesa finiva al primo giro",
                    at: Date().addingTimeInterval(-3000)
                ),
                ClaudeMessage(
                    author: .user,
                    text: "Ha funzionato!",
                    at: Date().addingTimeInterval(-120)
                ),
            ],
            emptyExplanation: "Niente da leggere."
        )
    }
    .preferredColorScheme(.dark)
}
