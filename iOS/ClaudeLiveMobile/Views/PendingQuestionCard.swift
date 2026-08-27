import SwiftUI
import ClaudeLiveKit

/// Una domanda a scelta multipla, con le sue opzioni e lo spazio per scriverne
/// una propria.
///
/// Compare in due posti e con due intenzioni diverse. In Home è un'anteprima: si
/// può rispondere subito, e c'è un pulsante per entrare nella chat quando la
/// domanda da sola non basta a decidere. Dentro la chat è in fondo allo schermo,
/// chiusa, e si apre dopo aver letto — che è l'ordine giusto: prima si legge,
/// poi si risponde.
///
/// Il pezzo che vale la pena raccontare è perché esiste. Prima, una domanda
/// trattenuta arrivava sul telefono travestita da richiesta di permesso, con
/// «Consenti» e «Nega» al posto delle opzioni: premere non rispondeva niente,
/// liberava la chiamata, e la domanda finiva nel terminale — dove non c'era
/// nessuno, perché il telefono si usa quando si è altrove.
struct PendingQuestionCard: View {
    let session: ClaudeSessionStatus
    let questions: [ClaudeQuestion]
    let isInFlight: Bool

    /// Il pulsante per andare a leggere la chat. Assente quando la scheda è già
    /// dentro la chat: là non c'è nessun posto dove andare.
    let onReadChat: (() -> Void)?

    let onAnswer: (ClaudeSessionStatus, [String: String]) -> Void

    @State private var answers: [String: String] = [:]
    @State private var chosen: Set<String> = []
    @State private var writingOwn = false
    @State private var ownAnswer = ""
    @FocusState private var writing: Bool

    private var current: ClaudeQuestion? {
        questions.first { answers[$0.question] == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let question = current {
                Text(question.question)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                if isInFlight {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("risposta in viaggio…")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                } else {
                    ForEach(question.options) { option in
                        optionRow(option, in: question)
                    }
                    actions(for: question)
                }
            } else {
                Label("Risposta inviata", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(GlowRGB.done.color)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(state: session.state)
            Text(session.projectName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            if let question = current, !question.header.isEmpty {
                Text(question.header)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(GlowRGB.waiting.color.opacity(0.22), in: Capsule())
            }

            Spacer(minLength: 4)

            if questions.count > 1, let question = current,
               let index = questions.firstIndex(of: question) {
                Text("\(index + 1) di \(questions.count)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func optionRow(_ option: ClaudeQuestion.Option, in question: ClaudeQuestion) -> some View {
        let isChosen = chosen.contains(option.label)
        return Button {
            if question.multi {
                if isChosen { chosen.remove(option.label) } else { chosen.insert(option.label) }
            } else {
                record(option.label, for: question)
            }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                if question.multi {
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isChosen ? GlowRGB.done.color : .white.opacity(0.35))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.footnote.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    // La descrizione è la differenza fra scegliere e indovinare.
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(isChosen ? 0.14 : 0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isChosen ? GlowRGB.done.color.opacity(0.6) : .white.opacity(0.14),
                                lineWidth: isChosen ? 1.2 : 0.5
                            )
                    }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func actions(for question: ClaudeQuestion) -> some View {
        VStack(spacing: 8) {
            if writingOwn {
                HStack(spacing: 8) {
                    TextField("La tua risposta", text: $ownAnswer, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.footnote)
                        .focused($writing)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))

                    Button {
                        sendOwnAnswer(for: question)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(ownAnswerIsEmpty)
                    .foregroundStyle(ownAnswerIsEmpty ? .white.opacity(0.25) : GlowRGB.done.color)
                }
            }

            HStack(spacing: 10) {
                if question.multi {
                    Button {
                        // Nell'ordine in cui le opzioni sono scritte, non in
                        // quello in cui sono state toccate: è l'ordine che Claude
                        // ha scelto per presentarle.
                        record(
                            ClaudeQuestion.joined(
                                question.options.map(\.label).filter(chosen.contains)
                            ),
                            for: question
                        )
                    } label: {
                        Text("Rispondi").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(GlowRGB.done.color)
                    .disabled(chosen.isEmpty)
                }

                if !writingOwn {
                    Button {
                        writingOwn = true
                        writing = true
                    } label: {
                        Label("Altro…", systemImage: "pencil")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }

                if let onReadChat {
                    // Perché la domanda da sola a volte non basta: quello che
                    // Claude ha scritto prima è metà della decisione.
                    Button(action: onReadChat) {
                        Label("Leggi la chat", systemImage: "text.bubble")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var ownAnswerIsEmpty: Bool {
        ownAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendOwnAnswer(for question: ClaudeQuestion) {
        guard !ownAnswerIsEmpty else { return }
        record(ownAnswer.trimmingCharacters(in: .whitespacesAndNewlines), for: question)
    }

    /// Registra una risposta e, quando le domande sono finite, le manda tutte.
    ///
    /// Insieme e non una per volta: l'hook trattiene *una* chiamata, e quella
    /// chiamata vuole tutte le sue risposte in un colpo.
    private func record(_ value: String, for question: ClaudeQuestion) {
        answers[question.question] = value
        chosen = []
        ownAnswer = ""
        writingOwn = false
        writing = false
        if questions.allSatisfy({ answers[$0.question] != nil }) {
            onAnswer(session, answers)
        }
    }
}
