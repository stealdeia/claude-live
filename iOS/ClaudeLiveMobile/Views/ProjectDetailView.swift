import SwiftUI
import ClaudeLiveKit

/// One project, chat by chat.
struct ProjectDetailView: View {
    let project: ClaudeProjectStatus
    let sessions: [ClaudeSessionStatus]
    let inFlight: Set<String>

    /// Gli ultimi messaggi di ogni conversazione, per identificativo di sessione.
    /// Vuoto se il Mac è più vecchio di questa versione dell'app.
    let messages: [String: [ClaudeMessage]]

    /// Le domande a scelta multipla in attesa, per identificativo di sessione.
    let questions: [String: [ClaudeQuestion]]

    let onDecide: (ClaudeSessionStatus, Bool, Bool) -> Void
    let onAnswer: (ClaudeSessionStatus, [String: String]) -> Void
    /// Il seguito scritto dal telefono, quando la conversazione lo sta aspettando.
    let onPrompt: (ClaudeSessionStatus, String) -> Void

    var body: some View {
        ZStack {
            ThemedBackground()
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(sessions) { session in
                        NavigationLink {
                            chat(for: session)
                        } label: {
                            GlassCard {
                                chatRow(session)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Text(project.projectPath)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle((project.projectPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// La chat di una sessione, con tutto ciò che le appartiene.
    ///
    /// Costruita qui e non nel punto in cui si tocca la riga perché serve a due
    /// chiamanti: la riga, e — per un progetto con una chat sola — chi salta
    /// questo elenco del tutto.
    @ViewBuilder
    func chat(for session: ClaudeSessionStatus) -> some View {
        ChatDetailView(
            session: session,
            isInFlight: inFlight.contains(session.id),
            messages: messages[session.sessionID] ?? [],
            questions: questions[session.sessionID] ?? [],
            onDecide: onDecide,
            onAnswer: onAnswer,
            onPrompt: onPrompt
        )
    }

    private func chatRow(_ session: ClaudeSessionStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                StatusDot(state: session.state, isStale: session.isStale)
                Text(session.chatLabel)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(Format.age(since: session.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }

            Text(session.activityLabel)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Una chat: quello che si sono detti, e come rispondere senza uscire.
///
/// Lo schermo è della conversazione. Lo stato è una riga sottile in cima, e la
/// cosa da rispondere una barra in fondo, chiusa: si legge prima e si risponde
/// dopo, che è l'ordine in cui si decide.
struct ChatDetailView: View {
    let session: ClaudeSessionStatus
    let isInFlight: Bool

    /// Gli ultimi messaggi leggibili, dal più vecchio al più recente.
    let messages: [ClaudeMessage]

    /// Le domande a scelta multipla in attesa su questa chat.
    let questions: [ClaudeQuestion]

    let onDecide: (ClaudeSessionStatus, Bool, Bool) -> Void
    let onAnswer: (ClaudeSessionStatus, [String: String]) -> Void
    /// Il seguito scritto da qui, per far proseguire la conversazione sul Mac.
    let onPrompt: (ClaudeSessionStatus, String) -> Void

    /// Chiuso all'apertura: chi entra qui viene a leggere. Si apre dopo.
    @State private var showingRequest = false

    /// L'avviso che sta illuminando l'app, per poterlo spegnere entrando.
    @EnvironmentObject private var glowState: GlowState

    /// Serve solo a sapere *quale* avviso è in corso: la fotografia non arriva
    /// fino a questa vista, e passarla da tre livelli di viste per un solo campo
    /// sarebbe peggio.
    @EnvironmentObject private var alerts: CurrentAlert

    var body: some View {
        ZStack {
            ThemedBackground()
            ChatMessagesView(
                messages: messages,
                emptyExplanation: emptyExplanation,
                activity: (session.state, session.activityLabel)
            )
        }
        .safeAreaInset(edge: .top) { stateStrip }
        .safeAreaInset(edge: .bottom) { requestBar }
        // Nascosta la barra delle schede: dentro una chat si legge, e le tre
        // schede non servono — c'è il pulsante indietro. Ma soprattutto la
        // richiesta in fondo le finiva addosso, «pericolosamente vicino al menu
        // centrale sottostante», e la cosa importante della schermata non può
        // essere quella che si rischia di mancare.
        .toolbar(.hidden, for: .tabBar)
        // Aprire la chat *è* la presa in carico: chiedere anche di premere
        // qualcosa per spegnere la luce sarebbe un secondo gesto per la stessa
        // decisione. Lo spegnimento è graduale, e lo decide chi disegna il
        // segnale.
        .onAppear {
            glowState.seen(
                sessionID: session.sessionID,
                projectPath: session.projectPath,
                alert: alerts.alert
            )
        }
        .navigationTitle(session.chatLabel)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Una riga, non una scheda: lo stato serve a inquadrare quello che si legge,
    /// e una scheda alta mezzo schermo ruberebbe il posto alla conversazione.
    private var stateStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: session.state.symbol)
                .font(.caption)
                .foregroundStyle(session.state.tint)
            Text(session.state.label)
                .font(.caption.weight(.semibold))
            Text(session.activityLabel)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(Format.age(since: session.updatedAt))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    /// La domanda — o il permesso — appiccicata in fondo, dentro un accordion.
    @ViewBuilder
    private var requestBar: some View {
        if !questions.isEmpty {
            accordion(
                title: "Claude ti ha fatto una domanda",
                symbol: "questionmark.bubble.fill"
            ) {
                PendingQuestionCard(
                    session: session,
                    questions: questions,
                    isInFlight: isInFlight,
                    // Nessun pulsante «leggi la chat»: la chat è questa.
                    onReadChat: nil,
                    onAnswer: onAnswer
                )
            }
        } else if session.isDecidable {
            accordion(
                title: "Claude chiede un permesso",
                symbol: "lock.open.fill"
            ) {
                PendingDecisionCard(
                    session: session,
                    isInFlight: isInFlight,
                    onDecide: onDecide
                )
            }
        } else if session.acceptsPrompt {
            // Aperta e non dentro un accordion, al contrario delle altre due: là
            // si legge prima e si decide dopo, qui non c'è niente da decidere —
            // c'è da scrivere, e una casella da aprire prima di poterci scrivere
            // sarebbe un gesto in più per niente.
            PromptComposer(session: session, isInFlight: isInFlight, onSend: onPrompt)
        }
    }

    /// La richiesta in fondo, chiusa.
    ///
    /// Rifatta perché era troppo piccola per quello che è: la cosa più importante
    /// della schermata aveva il carattere più piccolo e l'area toccabile più
    /// stretta. Ora la barra è alta abbastanza da prendersi senza mirare, il
    /// testo è leggibile a colpo d'occhio, e il colore dell'avviso la distingue
    /// dal resto dell'interfaccia invece di mimetizzarla.
    private func accordion<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeOut(duration: 0.22)) { showingRequest.toggle() }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(GlowRGB.waiting.color)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        Text(showingRequest ? "tocca per chiudere" : "tocca per rispondere")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    Spacer(minLength: 4)

                    Image(systemName: showingRequest ? "chevron.down" : "chevron.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                // Cinquantasei punti: più di quanto copra un dito, perché questa
                // è la riga che non si deve mancare.
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingRequest {
                content()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                // Una velatura del colore dell'avviso: la barra deve sembrare
                // parte dell'avviso, non parte dello sfondo.
                Rectangle().fill(GlowRGB.waiting.color.opacity(0.10))
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(GlowRGB.waiting.color.opacity(0.45))
                .frame(height: 1)
        }
    }

    /// Vuoto per due motivi diversi, e dirlo male sarebbe peggio che tacere: una
    /// chat può non avere ancora parole (solo lavoro con gli strumenti), oppure
    /// il Mac può essere una versione che non li manda.
    private var emptyExplanation: String {
        session.lastMessage
            ?? "Di questa conversazione non c'è ancora niente da leggere: può contenere solo lavoro con gli strumenti, oppure il Mac non l'ha ancora pubblicata. Non vuol dire che Claude non abbia scritto."
    }
}

#Preview("Progetto") {
    let snapshot = RemoteSnapshot.sample(now: Date())
    return NavigationStack {
        ProjectDetailView(
            project: snapshot.projects[0],
            sessions: snapshot.sessions.filter { $0.projectPath == snapshot.projects[0].projectPath },
            inFlight: [],
            messages: snapshot.messages ?? [:],
            questions: snapshot.questions ?? [:],
            onDecide: { _, _, _ in },
            onAnswer: { _, _ in },
            onPrompt: { _, _ in }
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Chat con domanda") {
    NavigationStack {
        ChatDetailView(
            session: RemoteSnapshot.sample(now: Date()).sessions[0],
            isInFlight: false,
            messages: [
                ClaudeMessage(
                    author: .user,
                    text: "Sistemami il pannello.",
                    at: Date().addingTimeInterval(-9000)
                ),
                ClaudeMessage(
                    author: .assistant,
                    text: "Era una **variabile sovrascritta**: l'attesa finiva al primo giro.",
                    at: Date().addingTimeInterval(-90)
                ),
            ],
            questions: [
                ClaudeQuestion(
                    question: "Pubblico la correzione o prima aggiungo una prova?",
                    header: "Rilascio",
                    multi: false,
                    options: [
                        .init(
                            label: "Prima la prova",
                            description: "Così il difetto non torna senza che nessuno se ne accorga."
                        ),
                        .init(
                            label: "Pubblica subito",
                            description: "La prova arriva dopo, nello stesso giorno."
                        ),
                    ]
                ),
            ],
            onDecide: { _, _, _ in },
            onAnswer: { _, _ in },
            onPrompt: { _, _ in }
        )
    }
    .preferredColorScheme(.dark)
}
