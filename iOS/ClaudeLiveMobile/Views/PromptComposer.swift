import SwiftUI
import ClaudeLiveKit

/// La casella per far proseguire da qui una conversazione aperta sul Mac.
///
/// ## Quando compare
///
/// Solo mentre l'hook sul Mac sta trattenendo la fine di un turno, che è l'unico
/// momento in cui si può scrivere dentro una conversazione viva di VS Code:
/// Claude ha finito, l'hook non ha ancora chiuso, e ciò che arriva da qui fa
/// ripartire quel turno — stessa chat, nessuno stacco, nessuna biforcazione.
///
/// Fuori da quella finestra non c'è nessuno a raccogliere. Per questo la casella
/// non è sempre lì: una casella di testo sempre presente prometterebbe una cosa
/// che quasi sempre non funzionerebbe, e una promessa così è peggio della sua
/// assenza.
///
/// ## Perché non sparisce mentre scrivi
///
/// L'attesa può scadere — o si può tornare al Mac — proprio mentre si sta
/// scrivendo. Togliere la casella in quell'istante farebbe sparire sotto le dita
/// le parole già scritte. Resta, con scritto che non arriverebbe: perdere il
/// testo è peggio che leggerlo con un avviso sopra.
struct PromptComposer: View {
    let session: ClaudeSessionStatus
    let isInFlight: Bool
    let onSend: (ClaudeSessionStatus, String) -> Void

    @State private var text = ""
    @FocusState private var writing: Bool

    /// Il raggio degli angoli del campo di testo.
    private static let corner: CGFloat = 20

    private var canSend: Bool {
        session.acceptsPrompt && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isInFlight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let waiting = whyNotNow {
                Label(waiting.text, systemImage: waiting.symbol)
                    .font(.caption2)
                    .foregroundStyle(waiting.tint)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Scrivi a Claude…", text: $text, axis: .vertical)
                    .font(.subheadline)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($writing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    // Raggio fisso, non una capsula.
                    //
                    // Una capsula ha il raggio pari a metà della propria altezza:
                    // finché la riga è una sola sembra giusta, ma questo campo
                    // cresce fino a cinque righe, e a quel punto i fianchi
                    // rientrano di una cinquantina di punti e si mangiano il testo
                    // della prima e dell'ultima riga. Venti punti restano tondi
                    // quanto serve a una riga e non cambiano niente a cinque.
                    .background(
                        RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                            .fill(.white.opacity(0.09))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                            .stroke(.white.opacity(writing ? 0.22 : 0.10), lineWidth: 1)
                    )
                    .disabled(!session.acceptsPrompt)

                Button(action: send) {
                    Image(systemName: isInFlight ? "ellipsis" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend ? Color.black : .white.opacity(0.35))
                        .frame(width: 34, height: 34)
                        .background(
                            Circle().fill(canSend ? Color.green : .white.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .animation(.easeOut(duration: 0.15), value: canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    /// Perché non si può scrivere adesso, quando non si può.
    ///
    /// Due casi diversi che meritano due frasi diverse. Se Claude sta lavorando
    /// non c'è niente di rotto: sta rispondendo, e fra poco si potrà scrivere di
    /// nuovo. Se invece l'attesa è scaduta o sei tornato al Mac, quel messaggio
    /// non lo raccoglierebbe nessuno, e va detto.
    private var whyNotNow: (text: String, symbol: String, tint: Color)? {
        guard !session.acceptsPrompt else { return nil }
        if session.state == .working {
            return ("Claude sta rispondendo: potrai scrivere quando ha finito.",
                    "ellipsis.bubble", .white.opacity(0.5))
        }
        return ("La conversazione non aspetta più: questo messaggio non arriverebbe.",
                "exclamationmark.circle", .orange.opacity(0.9))
    }

    private func send() {
        let written = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !written.isEmpty else { return }
        onSend(session, written)
        text = ""
        writing = false
    }
}
