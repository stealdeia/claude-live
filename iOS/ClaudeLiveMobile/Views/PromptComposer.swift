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

    /// Quello che è stato mandato e non si è ancora visto tornare indietro.
    ///
    /// Il seguito compare nella chat solo quando il Mac rimanda la fotografia, e
    /// nel mezzo — che può essere qualche secondo — non ci sarebbe traccia di
    /// averlo mandato. Senza questo, si preme invio e non succede niente
    /// visibile: il gesto più facile da ripetere per sbaglio.
    @State private var justSent: String?

    private var canSend: Bool {
        session.acceptsPrompt && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isInFlight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let justSent {
                sentRow(justSent)
            }

            if !session.acceptsPrompt {
                Label(
                    "La conversazione non aspetta più: questo messaggio non arriverebbe.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption2)
                .foregroundStyle(.orange.opacity(0.9))
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Scrivi a Claude…", text: $text, axis: .vertical)
                    .font(.subheadline)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($writing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.09))
                    )
                    .overlay(
                        Capsule(style: .continuous)
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
        // Il messaggio è tornato indietro dentro la conversazione: la riga di
        // attesa ha finito il suo lavoro. Confrontato sul testo perché è l'unica
        // cosa che i due lati condividono — l'identificativo lo assegna il Mac.
        .onChange(of: session.updatedAt) { _, _ in
            if justSent != nil, session.state == .working { justSent = nil }
        }
    }

    private func send() {
        let written = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !written.isEmpty else { return }
        onSend(session, written)
        justSent = written
        text = ""
        writing = false
    }

    /// Quello che si è appena mandato, in attesa di rivederlo nella chat.
    private func sentRow(_ written: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            ProgressView()
                .controlSize(.mini)
                .tint(.white.opacity(0.5))
            Text(written)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}
