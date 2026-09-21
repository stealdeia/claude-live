import SwiftUI
import ClaudeLiveKit
import MascotCore

/// Cosa c'è dentro il fumetto.
enum MascotBubbleContent: Equatable {
    /// È appena successo qualcosa: una riga sola.
    case notice(MascotNotice)
    /// Quello che è rimasto in sospeso, cliccando il personaggio.
    case inbox([MascotInbox.Item])
}

/// Il fumetto sopra la testa.
///
/// Una riga per cosa, sempre, con i puntini quando il testo non ci sta: è un
/// fumetto, non una finestra. Quello che non ci sta dentro sta nel progetto, e
/// il fumetto serve a portartici.
///
/// Quando Claude sta aspettando una risposta — un permesso, o una domanda con
/// delle opzioni — i pulsanti sono qui dentro: rispondere dalla mascotte è la
/// stessa cosa che rispondere dal pannello, e mandare l'utente a cercare la
/// finestra giusta per premere «Consenti» vanificherebbe metà del motivo per
/// cui la mascotte esiste.
struct MascotBubbleView: View {
    let content: MascotBubbleContent
    /// Dove sta la punta, misurata dal bordo sinistro del fumetto: sotto il
    /// personaggio, ovunque sia finito rispetto alla nuvoletta.
    let tailOffset: CGFloat
    let onDismiss: () -> Void
    let onOpen: (MascotInbox.Item) -> Void
    let onDecide: (MascotInbox.Item, Bool) -> Void
    let onAnswer: (MascotInbox.Item, ClaudeQuestion, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            box
            Triangle()
                .fill(.regularMaterial)
                .frame(width: 14, height: MascotLayout.bubbleTail)
                .offset(x: tailOffset - MascotLayout.accessoryWidth / 2)
        }
        .frame(width: MascotLayout.accessoryWidth)
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch content {
            case .notice(let notice):
                line(
                    kind: notice.kind,
                    text: notice.headline,
                    detail: notice.detail,
                    action: onDismiss
                )
            case .inbox(let items):
                ForEach(items.prefix(MascotLayout.bubbleMaxRows)) { item in
                    line(
                        kind: item.kind,
                        text: item.project,
                        detail: item.detail,
                        action: { onOpen(item) }
                    )
                    if items.count == 1 { actions(for: item) }
                }
                if items.count > MascotLayout.bubbleMaxRows {
                    Text("e altri \(items.count - MascotLayout.bubbleMaxRows)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: MascotLayout.accessoryWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial)
        )
        .overlay(alignment: .leading) {
            // La traccia arancione: è il colore di Claude, ed è ciò che lega il
            // fumetto a chi sta parlando.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(MascotLayout.claudeOrange)
                .frame(width: 3)
                .padding(.vertical, 6)
                .padding(.leading, 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(MascotLayout.claudeOrange.opacity(0.35), lineWidth: 1)
        )
    }

    /// Una riga: icona, testo, e i puntini quando non ci sta.
    private func line(
        kind: MascotNotice.Kind, text: String, detail: String?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon(kind))
                    .foregroundStyle(tint(kind))
                    .font(.system(size: 11, weight: .semibold))
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            // Una riga sola, e il troncamento in fondo: il testo lungo di una
            // domanda o di un errore deve *finire con i puntini*, non mandare a
            // capo un fumetto che allora crescerebbe a ogni notizia.
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: MascotLayout.bubbleRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// I pulsanti per rispondere, quando c'è qualcosa a cui rispondere.
    @ViewBuilder
    private func actions(for item: MascotInbox.Item) -> some View {
        if let question = item.questions.first {
            ForEach(question.options.prefix(MascotLayout.bubbleMaxOptions)) { option in
                Button {
                    onAnswer(item, question, option.label)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9))
                            .foregroundStyle(MascotLayout.claudeOrange)
                        Text(option.label)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .frame(height: MascotLayout.bubbleRow)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else if item.decidable {
            HStack(spacing: 6) {
                Button("Consenti") { onDecide(item, true) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                Button("Nega") { onDecide(item, false) }
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .frame(height: MascotLayout.bubbleRow)
        }
    }

    private func icon(_ kind: MascotNotice.Kind) -> String {
        switch kind {
        case .finished: return "checkmark.circle.fill"
        case .needsYou: return "questionmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ kind: MascotNotice.Kind) -> Color {
        switch kind {
        case .finished: return Color(red: 0.24, green: 0.72, blue: 0.44)
        case .needsYou: return MascotLayout.claudeOrange
        case .failed: return Color(red: 0.92, green: 0.34, blue: 0.32)
        }
    }
}

/// La punta del fumetto.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
