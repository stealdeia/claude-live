import SwiftUI
import MascotCore

/// La barra sotto il personaggio.
///
/// Piccola apposta: non è una finestra di chat, è il posto dove buttare giù la
/// frase che ti è venuta in mente mentre Claude sta lavorando. La riga sotto
/// dice sempre **dove andrà a finire** quello che scrivi, perché la stessa
/// barra fa tre cose diverse a seconda del momento — risponde a una domanda,
/// manda subito, o mette in coda — e non dirlo la renderebbe imprevedibile.
///
/// ## Due stati, e il motivo
///
/// In `invito` è un finto campo: un guscio su cui si clicca. In `scrittura` è un
/// campo vero, e la finestra si prende la tastiera.
///
/// La differenza serve quando la barra compare **da sola**, insieme al fumetto,
/// perché Claude ha finito o ha chiesto qualcosa: in quel momento prendersi la
/// tastiera sarebbe un furto — stai scrivendo altrove e le lettere finirebbero
/// qui dentro. Così invece la riga è lì pronta, e la tastiera passa di qua solo
/// quando la clicchi.
struct MascotInputBar: View {
    @ObservedObject var appearance: MascotAppearance
    @ObservedObject var router: MascotPromptRouter
    let onSubmit: () -> Void
    let onClose: () -> Void

    @FocusState private var focused: Bool

    private var canSend: Bool {
        router.target.acceptsText
            && !appearance.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 2) {
            field
            Text(appearance.notice ?? hint)
                .font(.system(size: 10))
                .foregroundStyle(appearance.notice == nil ? Color.secondary : Color.accentColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: MascotLayout.accessoryWidth, height: MascotLayout.hintHeight)
        }
        .frame(width: MascotLayout.accessoryWidth)
    }

    @ViewBuilder
    private var field: some View {
        HStack(spacing: 6) {
            if appearance.barMode == .typing {
                TextField(placeholder, text: $appearance.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit { if canSend { onSubmit() } }
                    .disabled(!router.target.acceptsText)
                    .onAppear { focused = true }
                    // La finestra diventa attiva un istante dopo essere stata
                    // mostrata: chiedere il fuoco solo in `onAppear` arriva
                    // troppo presto e non succede niente. Il controller lo
                    // richiede di nuovo quando la tastiera è davvero sua.
                    .onChange(of: appearance.focusTick) { _, _ in focused = true }
            } else {
                Text(appearance.draft.isEmpty ? placeholder : appearance.draft)
                    .font(.system(size: 12))
                    .foregroundStyle(appearance.draft.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if router.queued != nil {
                Button {
                    router.cancelQueued()
                } label: {
                    Image(systemName: "clock.badge.xmark")
                }
                .buttonStyle(.plain)
                .help("Togli dalla coda il messaggio non ancora consegnato")
            }

            Button(action: onSubmit) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 10)
        .frame(width: MascotLayout.accessoryWidth, height: MascotLayout.barFieldHeight)
        .background(Capsule().fill(.regularMaterial))
        .overlay(
            Capsule().strokeBorder(
                appearance.barMode == .typing
                    ? Color.accentColor.opacity(0.55)
                    : Color.primary.opacity(0.12),
                lineWidth: 1
            )
        )
        // Esc chiude senza mandare niente: la via d'uscita più prevedibile che
        // ci sia, e senza di essa la barra si chiuderebbe solo cliccando altrove.
        .onExitCommand(perform: onClose)
    }

    private var placeholder: String {
        switch router.target {
        case .question: return "Rispondi a Claude…"
        case .followUp: return "Scrivi a Claude…"
        case .queue: return "Scrivi: parte quando ha finito…"
        case .permission, .none: return "Niente a cui scrivere"
        }
    }

    /// Dove va a finire quello che scrivi. Cambia da solo insieme a quello che
    /// Claude sta facendo, anche mentre la barra è aperta.
    private var hint: String {
        if let queued = router.queued {
            return "In coda: \(queued)"
        }
        switch router.target {
        case .question(_, let project, let question):
            return "\(project) chiede: \(question)"
        case .followUp(_, let project):
            return "Va subito a \(project)"
        case .queue(_, let project):
            return "Parte quando \(project) ha finito"
        case .permission(let project):
            return "\(project) chiede un permesso: rispondi dal pannello"
        case .none:
            return "Nessuna chat aperta a cui scrivere"
        }
    }
}
