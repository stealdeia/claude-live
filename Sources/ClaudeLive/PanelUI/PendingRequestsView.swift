import SwiftUI
import ClaudeLiveKit

/// Everything Claude Code is currently waiting on, split by what the user can
/// actually do about it.
///
/// **Da approvare** — permission requests. The hook that raised them is blocked
/// waiting for an answer, so Allow/Deny here decides them outright: no need to
/// find the right terminal.
///
/// **Domande aperte** — anything else Claude is waiting on (a question, a
/// choice). Those can only be answered in the session itself, so the row's job is
/// to bring the right window forward.
///
/// The split is not cosmetic: it maps onto which hook event fired, and therefore
/// onto whether an answer from here can reach Claude Code at all.
struct PendingRequestsView: View {
    @ObservedObject var status: ClaudeStatusStore

    /// Brings the window of a given project path forward.
    let onFocusProject: (String) -> Void

    private var decidable: [ClaudeSessionStatus] {
        status.waitingSessions.filter(\.isDecidable)
    }

    /// Le domande a scelta multipla: in modalità automatica sono l'unica cosa che
    /// si ferma ad aspettare, quindi vanno per prime.
    private var questionsWaiting: [ClaudeSessionStatus] {
        decidable.filter { !(status.pendingQuestions[$0.sessionID] ?? []).isEmpty }
    }

    private var permissionsWaiting: [ClaudeSessionStatus] {
        decidable.filter { (status.pendingQuestions[$0.sessionID] ?? []).isEmpty }
    }

    private var openQuestions: [ClaudeSessionStatus] {
        status.waitingSessions.filter(\.needsTerminal)
    }

    var body: some View {
        if !decidable.isEmpty || !openQuestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !questionsWaiting.isEmpty {
                    section(
                        title: "Da rispondere",
                        count: questionsWaiting.count,
                        tint: PanelTheme.color(for: .warning)
                    ) {
                        ForEach(questionsWaiting) { request in
                            QuestionRequestRow(
                                request: request,
                                questions: status.pendingQuestions[request.sessionID] ?? [],
                                status: status
                            )
                        }
                    }
                }

                if !permissionsWaiting.isEmpty {
                    section(
                        title: "Da approvare",
                        count: permissionsWaiting.count,
                        tint: PanelTheme.color(for: .warning)
                    ) {
                        ForEach(permissionsWaiting) { request in
                            DecidableRequestRow(request: request, status: status)
                        }
                    }
                }

                if !openQuestions.isEmpty {
                    section(
                        title: "Domande aperte",
                        count: openQuestions.count,
                        tint: PanelTheme.secondaryText
                    ) {
                        ForEach(openQuestions) { request in
                            OpenQuestionRow(request: request) {
                                onFocusProject(request.projectPath)
                                status.clearAlert(forPath: request.projectPath)
                            }
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(
        title: String,
        count: Int,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title)
                    .font(PanelTheme.labelFont)
                    .foregroundStyle(tint)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(PanelTheme.captionFont)
                    .foregroundStyle(tint)
            }
            content()
        }
    }
}

/// Una domanda a scelta multipla, con le sue opzioni e lo spazio per scriverne
/// una propria.
///
/// Perché sta nel pannello: in modalità automatica i permessi non si chiedono
/// più, e una domanda è l'unica cosa che ferma la sessione ad aspettare una
/// persona. Rispondere qui vuol dire non dover cercare la finestra giusta.
///
/// Una chiamata può portare più domande: si mostra la prima senza risposta e le
/// altre arrivano dopo, perché nel pannello non c'è spazio per quattro domande e
/// affastellarle renderebbe illeggibili tutte.
private struct QuestionRequestRow: View {
    let request: ClaudeSessionStatus
    let questions: [ClaudeQuestion]
    @ObservedObject var status: ClaudeStatusStore

    /// Le risposte già date, per testo della domanda — la chiave con cui Claude
    /// Code le indirizza.
    @State private var answers: [String: String] = [:]

    /// Le opzioni spuntate della domanda in corso, quando ne ammette più di una.
    @State private var chosen: Set<String> = []

    @State private var writingOwn = false
    @State private var ownAnswer = ""

    private var current: ClaudeQuestion? {
        questions.first { answers[$0.question] == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let question = current {
                Text(question.question)
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(question.options) { option in
                    optionRow(option, in: question)
                }

                actions(for: question)
            } else {
                // Tutte risposte: il file di stato tornerà «al lavoro» fra un
                // istante, e nel frattempo è meglio dire che è partita.
                Text("Risposta inviata.")
                    .font(.system(size: 10))
                    .foregroundStyle(PanelTheme.secondaryText)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PanelTheme.color(for: .warning).opacity(0.12))
        )
    }

    private var header: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(PanelTheme.color(for: .warning))
                .frame(width: 6, height: 6)

            Text(request.projectName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)

            if let question = current, !question.header.isEmpty {
                Text(question.header)
                    .font(.system(size: 8.5, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(GlowRGB.waiting.color.opacity(0.22), in: Capsule())
            }

            Spacer(minLength: 2)

            // Solo quando ce n'è più di una: «1 di 1» è rumore.
            if questions.count > 1, let question = current,
               let index = questions.firstIndex(of: question) {
                Text("\(index + 1) di \(questions.count)")
                    .font(.system(size: 9))
                    .foregroundStyle(PanelTheme.secondaryText)
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
            HStack(alignment: .top, spacing: 6) {
                if question.multi {
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(isChosen ? GlowRGB.done.color : Color.primary.opacity(0.35))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    // La descrizione è la differenza fra scegliere e indovinare,
                    // quindi c'è. Tre righe: oltre, il pannello diventa un muro.
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 9.5))
                            .foregroundStyle(PanelTheme.secondaryText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 2)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // Rettangolo stondato e non capsula come i pulsanti dei permessi:
                // qui il contenuto è su due o tre righe, e una capsula attorno a
                // un paragrafo sembra un errore.
                let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
                shape.fill(Color.primary.opacity(isChosen ? 0.14 : 0.07))
                    .overlay {
                        shape.strokeBorder(
                            isChosen ? GlowRGB.done.color.opacity(0.55) : Color.primary.opacity(0.16),
                            lineWidth: isChosen ? 1 : 0.5
                        )
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func actions(for question: ClaudeQuestion) -> some View {
        if writingOwn {
            HStack(spacing: 6) {
                // La casella prende il fuoco senza attivare l'app: le due
                // finestre del pannello sono `becomesKeyOnlyIfNeeded`, quindi
                // scrivere qui non porta via il primo piano a nessuno.
                TextField("La tua risposta", text: $ownAnswer)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.28), in: Capsule())
                    .onSubmit { sendOwnAnswer(for: question) }

                pill("Invia", tint: GlowRGB.done.color, enabled: !ownAnswerIsEmpty) {
                    sendOwnAnswer(for: question)
                }
                pill("Annulla") {
                    writingOwn = false
                    ownAnswer = ""
                }
            }
        } else {
            HStack(spacing: 6) {
                if question.multi {
                    pill("Rispondi", tint: GlowRGB.done.color, enabled: !chosen.isEmpty) {
                        // Nell'ordine in cui le opzioni sono scritte, non in
                        // quello in cui sono state spuntate: è l'ordine che
                        // Claude ha scelto per presentarle.
                        record(
                            ClaudeQuestion.joined(
                                question.options.map(\.label).filter(chosen.contains)
                            ),
                            for: question
                        )
                    }
                }

                pill("Altro…") { writingOwn = true }
                    .help("Scrivi una risposta tua invece di scegliere fra le opzioni")

                Spacer(minLength: 2)
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

    /// Registra una risposta e, se sono finite le domande, la manda.
    ///
    /// Mandate tutte insieme e non una per volta: l'hook trattiene *una*
    /// chiamata, e quella chiamata vuole tutte le sue risposte in un colpo.
    private func record(_ value: String, for question: ClaudeQuestion) {
        answers[question.question] = value
        chosen = []
        ownAnswer = ""
        writingOwn = false
        if questions.allSatisfy({ answers[$0.question] != nil }) {
            status.answer(request, answers: answers)
        }
    }

    private func pill(
        _ title: String,
        tint: Color = Color.primary.opacity(0.6),
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? tint : tint.opacity(0.35))
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(tint.opacity(enabled ? 0.16 : 0.06), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A permission request that can be answered from here.
private struct DecidableRequestRow: View {
    let request: ClaudeSessionStatus
    @ObservedObject var status: ClaudeStatusStore

    @State private var isHovering = false
    @State private var confirmingAlways = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(PanelTheme.color(for: .warning))
                    .frame(width: 6, height: 6)

                Text(request.projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                if let tool = request.toolName, !tool.isEmpty {
                    Text(tool)
                        .font(.system(size: 9.5, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(GlowRGB.waiting.color.opacity(0.22), in: Capsule())
                }

                Spacer(minLength: 2)
            }

            // What Claude actually wants to do. Without it the buttons would be
            // asking the user to approve something unseen.
            if let summary = request.toolSummary {
                Text(summary)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(PanelTheme.secondaryText)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.black.opacity(0.28))
                    )
            }

            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    // Verde pieno contro contorno neutro, come sull'iPhone: la
                    // stessa richiesta risponde uguale sui due schermi, e chi
                    // arriva dal telefono non deve rileggere i pulsanti.
                    wideButton("Consenti", filled: GlowRGB.done.color) {
                        status.decide(request, allow: true)
                    }
                    wideButton("Nega", filled: nil) {
                        status.decide(request, allow: false)
                    }
                }
                alwaysRow
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(PanelTheme.color(for: .warning).opacity(isHovering ? 0.16 : 0.10))
        )
        .onHover { isHovering = $0 }
    }

    /// La capsula larga dell'iPhone, sotto le altre due e dietro una conferma.
    ///
    /// Larga perché va trovata senza cercarla, e dietro una conferma perché le
    /// altre due rispondono a *questa* richiesta mentre questa risponde a tutte
    /// quelle come questa, per sempre. Prima era un bottoncino chiamato «Sempre»,
    /// grande come «Nega» e a un clic di distanza da esso.
    ///
    /// La conferma è in linea e non una finestra di sistema: il pannello si chiude
    /// quando perde il fuoco, e una finestra di conferma se lo prenderebbe,
    /// portandosi via la domanda a cui doveva servire.
    @ViewBuilder
    private var alwaysRow: some View {
        if confirmingAlways {
            HStack(spacing: 6) {
                Text("Non chiedere più?")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(PanelTheme.secondaryText)
                Spacer(minLength: 2)
                smallButton("Annulla") { confirmingAlways = false }
                smallButton("Sempre", tint: GlowRGB.waiting.color) {
                    confirmingAlways = false
                    status.decide(request, allow: true, remember: true)
                }
            }
            .padding(.vertical, 1)
        } else {
            Button { confirmingAlways = true } label: {
                Label("Consenti sempre questo comando", systemImage: "infinity")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6.5)
                    .background(Color.primary.opacity(0.09), in: Capsule())
                    .overlay { Capsule().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.5) }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Consenti ora e non chiedere più per questo comando identico, in questo progetto")
        }
    }

    /// Metà riga ciascuno: `filled` per il verde pieno, `nil` per il contorno.
    private func wideButton(
        _ title: String,
        filled: Color?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(filled == nil ? Color.primary.opacity(0.9) : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    // Capsule e non un rettangolo stondato: la stessa forma del
                    // pulsante «sempre» qui sotto, così i tre si leggono come tre
                    // risposte alla stessa domanda invece che come due più una.
                    if let filled {
                        Capsule().fill(filled)
                    } else {
                        Capsule().fill(Color.primary.opacity(0.10))
                            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.28), lineWidth: 0.8) }
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func smallButton(
        _ title: String,
        tint: Color = Color.primary.opacity(0.55),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(tint.opacity(0.16), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Something Claude is waiting on that only its own session can answer.
private struct OpenQuestionRow: View {
    let request: ClaudeSessionStatus
    let onSelect: () -> Void

    @State private var isHovering = false

    private var label: String {
        request.detail ?? request.requestKind ?? "in attesa di una risposta"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Circle()
                    .fill(PanelTheme.color(for: .warning))
                    .frame(width: 6, height: 6)

                Text(request.projectName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(PanelTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)

                Spacer(minLength: 2)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PanelTheme.secondaryText)
                    .opacity(isHovering ? 1 : 0.4)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.09 : 0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Apri \(request.projectName) per rispondere")
    }
}
