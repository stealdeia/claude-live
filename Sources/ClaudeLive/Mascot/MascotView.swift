import SwiftUI
import ClaudeLiveKit
import MascotCore

/// In che stato è la barra sotto il personaggio.
enum MascotBarMode: Equatable {
    /// Non c'è.
    case hidden
    /// C'è, ma è un guscio: ci si clicca sopra per cominciare a scrivere. Vedi
    /// `MascotInputBar`.
    case invite
    /// Campo vero, con la tastiera.
    case typing
}

/// Quello che la mascotte sta facendo, per la parte che si vede *oltre* ai
/// fotogrammi.
///
/// Un oggetto osservabile e non dei parametri della vista perché chi lo aggiorna
/// è AppKit — il trascinamento arriva da `MascotDragView`, la disposizione dal
/// controller — e ricostruire la vista ospitata a ogni evento del mouse sarebbe
/// un giro lungo per dire una cosa breve.
@MainActor
final class MascotAppearance: ObservableObject {
    /// Inclinazione in gradi mentre la si trascina: positiva quando la si porta
    /// a destra. I fotogrammi dicono *cosa* sta facendo il personaggio, questa
    /// dice come lo stai muovendo tu — due cose diverse, e sommarle è ciò che fa
    /// sembrare che il pupazzetto subisca lo spostamento invece di seguirlo.
    @Published var tilt: Double = 0

    @Published var barMode: MascotBarMode = .hidden

    /// Il fumetto sopra la testa, quando c'è qualcosa da dire.
    @Published var bubble: MascotBubbleContent?

    /// Quante notizie non ancora viste: il pallino sulla testa.
    @Published var unread: Int = 0

    /// Quello che si sta scrivendo. Sopravvive alla chiusura della barra: una
    /// frase persa perché hai cliccato altrove è una frase da riscrivere.
    @Published var draft = ""

    /// L'esito dell'ultimo invio, per qualche secondo, al posto del suggerimento.
    @Published var notice: String?

    /// Cambia quando il campo deve prendersi il cursore. Vedi `MascotInputBar`.
    @Published var focusTick = 0

    /// Come sono disposti personaggio, fumetto e barra dentro la finestra.
    /// Lo calcola il controller con `MascotChromeLayout`.
    @Published var chrome: MascotChromeFrame?

    var isBarVisible: Bool { barMode != .hidden }
}

/// Il personaggio, con quello che ha attorno.
struct MascotView: View {
    @ObservedObject var animator: SpriteAnimator
    @ObservedObject var appearance: MascotAppearance
    @ObservedObject var router: MascotPromptRouter
    let onSubmit: () -> Void
    let onCloseBar: () -> Void
    let onDismissBubble: () -> Void
    let onOpenItem: (MascotInbox.Item) -> Void
    let onDecide: (MascotInbox.Item, Bool) -> Void
    let onAnswer: (MascotInbox.Item, ClaudeQuestion, String) -> Void

    var body: some View {
        // Le righe sopra e sotto e i loro rientri arrivano già decisi:
        // il personaggio **non si sposta** per far posto a niente, quindi la
        // disposizione non è una pila centrata ma l'unione di tre rettangoli
        // che possono essere sfalsati. Vedi `MascotChromeLayout`.
        VStack(alignment: .leading, spacing: MascotLayout.gap) {
            ForEach(Array(above.enumerated()), id: \.offset) { _, row in
                accessory(row)
            }

            character
                .frame(
                    width: MascotLayout.characterSize.width,
                    height: MascotLayout.characterSize.height
                )
                .overlay(alignment: .topTrailing) { badge }
                .rotationEffect(.degrees(appearance.tilt))
                .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.7), value: appearance.tilt)
                .padding(.leading, characterInset)

            ForEach(Array(below.enumerated()), id: \.offset) { _, row in
                accessory(row)
            }
        }
        .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
    }

    // MARK: - Disposizione

    private var above: [MascotRow] { appearance.chrome?.above ?? [] }
    private var below: [MascotRow] { appearance.chrome?.below ?? [] }
    private var characterInset: CGFloat { appearance.chrome?.characterInset ?? 0 }
    private var accessoryInset: CGFloat { appearance.chrome?.accessoryInset ?? 0 }

    private var panelSize: CGSize {
        appearance.chrome?.panel.size ?? MascotLayout.characterSize
    }

    @ViewBuilder
    private func accessory(_ row: MascotRow) -> some View {
        switch row {
        case .bubble:
            if let content = appearance.bubble {
                MascotBubbleView(
                    content: content,
                    tailOffset: characterInset + MascotLayout.characterSize.width / 2 - accessoryInset,
                    onDismiss: onDismissBubble,
                    onOpen: onOpenItem,
                    onDecide: onDecide,
                    onAnswer: onAnswer
                )
                .padding(.leading, accessoryInset)
                .transition(.opacity)
            }
        case .bar:
            MascotInputBar(
                appearance: appearance,
                router: router,
                onSubmit: onSubmit,
                onClose: onCloseBar
            )
            .padding(.leading, accessoryInset)
        }
    }

    /// Il pallino delle notizie non viste.
    ///
    /// Con il numero quando sono più di una, perché «ci sono novità» e «ci sono
    /// novità in tre progetti diversi» sono due informazioni diverse, e la
    /// seconda è quella che dice se conviene fermarsi a guardare.
    @ViewBuilder
    private var badge: some View {
        if appearance.unread > 0 {
            Text(appearance.unread > 1 ? "\(appearance.unread)" : " ")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(minWidth: appearance.unread > 1 ? 16 : 10, minHeight: 10)
                .padding(.horizontal, appearance.unread > 1 ? 3 : 0)
                .background(
                    Capsule().fill(MascotLayout.claudeOrange)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                .offset(x: 2, y: -2)
        }
    }

    // MARK: - Il personaggio

    @ViewBuilder
    private var character: some View {
        if let image = animator.image {
            Image(nsImage: image)
                .resizable()
                // Senza questo macOS sfuma i pixel ingranditi e la pixel art
                // diventa una macchia: è la riga che tiene i bordi netti.
                .interpolation(.none)
                .antialiased(false)
                .scaledToFit()
                // Niente `.animation` sul cambio di fotogramma: l'animazione
                // deve essere a scatti, ed è tutto il punto. Interpolare fra un
                // disegno e l'altro darebbe una dissolvenza continua.
                .transaction { $0.animation = nil }
        } else {
            // Nessun disegno caricato: meglio niente che un rettangolo che
            // sembra un errore grafico. Il perché sta nel log.
            Color.clear
        }
    }
}
