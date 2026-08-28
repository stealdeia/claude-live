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

    /// Cosa sta facendo Claude adesso, se sta facendo qualcosa.
    ///
    /// Sotto l'ultimo messaggio e non solo nella riga in cima: là si legge
    /// guardando lo stato, qui si legge **leggendo la conversazione** — che è
    /// dove si guarda quando si aspetta la riga dopo. È lo stesso posto dove
    /// qualsiasi app di messaggi mette «sta scrivendo…».
    var activity: (state: ClaudeActivity, label: String)?

    /// Ancora dell'ultimo messaggio, per portarci la vista all'apertura.
    /// Quello che è stato mandato dall'app e non si è ancora visto tornare.
    ///
    /// Disegnato come un fumetto vero, in fondo, un po' spento. Prima compariva
    /// solo una riguccia grigia dentro la casella di scrittura, e non si leggeva
    /// come «mandato»: si premeva invio e la conversazione non cambiava, che è il
    /// modo più sicuro di far premere invio due volte.
    var pending: String?

    private enum Anchor: Hashable { case bottom }

    /// Se l'ultimo messaggio è sotto gli occhi in questo momento.
    ///
    /// Decide se seguire la conversazione quando arriva qualcosa di nuovo. Senza
    /// questa distinzione ci sono solo due comportamenti, ed entrambi sbagliano:
    /// seguire sempre strappa la vista a chi sta leggendo più su, non seguire mai
    /// lascia la vista dov'era mentre il contenuto le cresce sotto — ed è così
    /// che «è sparita tutta la chat e ho dovuto scrollare in su».
    @State private var atBottom = true

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
                        // Per identità e non per posizione: quando la finestra
                        // dei venti scorre, le posizioni si spostano tutte di
                        // uno e ogni fumetto risultava «cambiato». Venti blocchi
                        // di testo formattato buttati e rifatti a ogni messaggio
                        // nuovo — la chat che rimbalza, i scatti, il telefono
                        // che scalda.
                        ForEach(messages) { message in
                            bubble(message)
                        }
                    }

                    if let pending, !pending.isEmpty {
                        // Il fumetto e, sotto, il segno che sta andando.
                        //
                        // Solo sbiadito non bastava: al cinquanta per cento su
                        // sfondo scuro si legge come un fantasma, non come «sto
                        // mandando», e chi ha premuto invio resta convinto che non
                        // sia successo niente. Il pallino che gira è la parte che
                        // dice *cosa sta facendo*, ed è la stessa cosa che
                        // qualunque app di messaggi mette accanto a un messaggio
                        // non ancora consegnato.
                        VStack(alignment: .trailing, spacing: 3) {
                            MessageBubble(
                                message: ClaudeMessage(author: .user, text: pending, at: nil)
                            )
                            .opacity(0.8)

                            HStack(spacing: 5) {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(.white.opacity(0.45))
                                Text("invio…")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            .padding(.trailing, 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    if let activity, activity.state == .working || activity.state == .waitingInput {
                        HStack(spacing: 7) {
                            StatusDot(state: activity.state, size: 7)
                            Text(activity.label)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 2)
                        .padding(.top, 2)
                    }

                    // Un punto invisibile in fondo, che è l'unico modo affidabile
                    // di dire «qui» a `scrollTo`: l'ultimo messaggio può essere
                    // alto una schermata, e portarsi al suo inizio lascerebbe
                    // fuori proprio la parte nuova.
                    Color.clear
                        .frame(height: 1)
                        .id(Anchor.bottom)
                        .onScrollVisibilityChange { atBottom = $0 }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            // Il modo giusto di aprirsi in fondo: deciso *prima* del disegno,
            // quindi non c'è nessun salto da vedere. Chiedere lo scorrimento in
            // `onAppear` funzionava a volte e a volte no — su una lista pigra
            // l'ultimo messaggio può non essere ancora disegnato nel momento in
            // cui glielo si chiede, e allora la richiesta cade nel vuoto.
            // Due ruoli su tre, e quello che manca è il difetto.
            //
            // `.defaultScrollAnchor(.bottom)` senza specificare per cosa vale
            // chiede tre cose insieme: apriti in fondo, allinea in fondo, **e
            // torna in fondo ogni volta che la dimensione cambia**. È la terza a
            // far rimbalzare: la riga «cosa sta facendo Claude» che compare e
            // sparisce, un fumetto che si apre, e soprattutto la tastiera —
            // aprendola l'area utile si accorcia, il che *è* un cambio di
            // dimensione, e la vista scattava in fondo mentre stavi scorrendo.
            // Da lì l'ultimo messaggio che scappa in alto e lo schermo vuoto.
            //
            // Aprirsi in fondo e allinearsi in fondo restano: sono ciò che si
            // vuole da una chat. Inseguire ogni cambio di dimensione no.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            // Scorrere la conversazione chiude la tastiera, seguendo il dito.
            //
            // È il gesto che tutte le app di messaggi hanno, e qui serve due
            // volte: chi scorre con la tastiera aperta sta cercando di *leggere*,
            // non di scrivere — e metà dello schermo occupato da una tastiera è
            // la ragione per cui non ci riusciva.
            .scrollDismissesKeyboard(.interactively)
            // Nessuno scorrimento quando cambia soltanto *cosa sta facendo*
            // Claude. Quella riga cambia a ogni strumento — Bash, Read, Bash —
            // cioè più volte al minuto mentre lavora, e ogni volta strappava la
            // vista in fondo a chi stava leggendo più su. La riga dell'attività è
            // alta poco: chi è in fondo la vede comunque, e chi non lo è non
            // voleva andarci.
            .onChange(of: messages.count) { _, _ in
                follow(proxy)
            }
            // Anche quando il messaggio in attesa compare o sparisce: sono le due
            // volte in cui la conversazione cresce di un fumetto senza che il
            // conto dei messaggi cambi.
            .onChange(of: pending) { _, _ in
                follow(proxy)
            }
        }
    }

    /// Scende in fondo, ma solo per chi ci era già.
    private func follow(_ proxy: ScrollViewProxy) {
        guard atBottom else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(Anchor.bottom, anchor: .bottom)
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
