import SwiftUI
import ClaudeLiveKit

/// The essentials, and a way into each of them.
///
/// The rule that shapes this screen: everything here answers a question in one
/// look, and anything that needs a second look belongs in its own tab. So the
/// projects appear as names and dots with no chats underneath, and the limits
/// as two rings with no dates — the details are one tap away, not absent.
struct HomeView: View {
    let snapshot: RemoteSnapshot?
    /// Why the screen may not be telling the truth: not paired, unreachable,
    /// wrong key. Shown above everything, because it changes how to read the
    /// rest of the page.
    var problem: String?
    let inFlight: Set<String>
    let onDecide: (ClaudeSessionStatus, Bool, Bool) -> Void
    let onAnswer: (ClaudeSessionStatus, [String: String]) -> Void
    let onOpenProjects: () -> Void
    let onOpenUsage: () -> Void

    @EnvironmentObject private var openRequest: OpenRequest
    @EnvironmentObject private var glow: GlowSettings
    @EnvironmentObject private var glowState: GlowState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let problem {
                    HStack(spacing: 9) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(GlowRGB.waiting.color)
                        Text(problem)
                            .font(.footnote)
                        Spacer()
                    }
                    .padding(12)
                    .background(GlowRGB.waiting.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                }

                if let snapshot {
                    pending(snapshot)
                    projects(snapshot)
                    usage(snapshot)
                    freshness(snapshot)
                } else {
                    waiting
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationDestination(item: $openRequest.chatSessionID) { sessionID in
            if let snapshot, let session = snapshot.sessions.first(where: { $0.sessionID == sessionID }) {
                ChatDetailView(
                    session: session,
                    isInFlight: inFlight.contains(session.id),
                    messages: snapshot.messages?[sessionID] ?? [],
                    questions: snapshot.questions?[sessionID] ?? [],
                    onDecide: onDecide,
                    onAnswer: onAnswer
                )
            }
        }
    }

    // MARK: - Quello che chiede attenzione

    @ViewBuilder
    private func pending(_ snapshot: RemoteSnapshot) -> some View {
        let decidable = snapshot.sessions.filter(\.isDecidable)
        let questions = snapshot.sessions.filter(\.needsTerminal)

        if !decidable.isEmpty {
            // Only the most urgent one, with its buttons. A queue of decisions
            // is a job, and a job belongs in the Projects tab; Home shows the
            // one that is blocking something right now.
            GlassCard {
                if let asked = snapshot.questions?[decidable[0].sessionID], !asked.isEmpty {
                    PendingQuestionCard(
                        session: decidable[0],
                        questions: asked,
                        isInFlight: inFlight.contains(decidable[0].id),
                        // Perché una domanda, a differenza di un permesso, a
                        // volte non si può decidere senza sapere cosa Claude
                        // stava facendo: il pulsante porta a leggerlo.
                        onReadChat: { openRequest.chatSessionID = decidable[0].sessionID },
                        onAnswer: onAnswer
                    )
                } else {
                    PendingDecisionCard(
                        session: decidable[0],
                        isInFlight: inFlight.contains(decidable[0].id),
                        onDecide: onDecide
                    )
                }
            }

            if decidable.count > 1 {
                Button {
                    onOpenProjects()
                } label: {
                    Label("altre \(decidable.count - 1) da rispondere", systemImage: "chevron.right")
                        .font(.footnote)
                        .labelStyle(TrailingIconLabel())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
            }
        } else if !questions.isEmpty {
            GlassCard {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .foregroundStyle(GlowRGB.waiting.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(questions.count) domanda\(questions.count == 1 ? "" : "e") aperta\(questions.count == 1 ? "" : "e")")
                            .font(.subheadline.weight(.medium))
                        Text("si risponde dal terminale")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                }
            }
        } else {
            GlassCard {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(GlowRGB.done.color)
                    Text("Nessuna richiesta in sospeso")
                        .font(.subheadline)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Progetti, ridotti all'osso

    /// I progetti: un pulsante per vederli tutti, e sotto la lista in cui ogni
    /// nome porta dentro il suo.
    ///
    /// Rifatta il 2026-08-27. Prima il nome non era toccabile e l'unica cosa da
    /// premere era una freccia piccola in cima: «è difficile cliccare sulla
    /// freccia», «ora è un po' stretto e faccio fatica a cliccare con le dita».
    /// Ogni riga ora è alta almeno 52 punti — un dito ne copre 44 — e si tocca
    /// tutta, nome compreso.
    private func projects(_ snapshot: RemoteSnapshot) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: onOpenProjects) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.footnote)
                        Text("Tutti i progetti")
                            .font(.subheadline.weight(.semibold))
                        if !snapshot.projects.isEmpty {
                            Text("\(snapshot.projects.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if snapshot.projects.isEmpty {
                    Text("Nessuna sessione aperta")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.bottom, 6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(snapshot.projects, id: \.projectPath) { project in
                            NavigationLink {
                                projectDestination(
                                    project: project,
                                    sessions: sessions(of: project, in: snapshot),
                                    inFlight: inFlight,
                                    messages: snapshot.messages ?? [:],
                                    questions: snapshot.questions ?? [:],
                                    onDecide: onDecide,
                                    onAnswer: onAnswer
                                )
                            } label: {
                                projectRow(project, in: snapshot)
                            }
                            .buttonStyle(.plain)

                            if project.projectPath != snapshot.projects.last?.projectPath {
                                Rectangle()
                                    .fill(.white.opacity(0.07))
                                    .frame(height: 0.5)
                            }
                        }
                    }
                }
            }
        }
    }

    private func projectRow(_ project: ClaudeProjectStatus, in snapshot: RemoteSnapshot) -> some View {
        let lit = glow.enabled
            && snapshot.alert?.projectPath == project.projectPath
            && glowState.isLit(snapshot.alert)

        return HStack(spacing: 11) {
            StatusDot(state: project.state, isStale: project.isStale, size: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text((project.projectPath as NSString).lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                Text(project.state.label)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
        // Cinquantadue punti: un dito ne copre quarantaquattro, e la riga deve
        // essere più larga del dito che la cerca.
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        // Pulsa la riga del progetto interessato, come fa sul Mac: la cornice
        // dice che c'è qualcosa, questa dice quale.
        .glowingRow(style: glow.style(for: snapshot.alert?.kind ?? .waiting), active: lit)
    }

    // MARK: - Utilizzo, due numeri

    @ViewBuilder
    private func usage(_ snapshot: RemoteSnapshot) -> some View {
        if let usage = snapshot.usage {
            GlassCard {
                VStack(spacing: 14) {
                    header("Utilizzo", count: nil, action: onOpenUsage)

                    HStack(spacing: 0) {
                        if let five = usage.fiveHour {
                            UsageRing(title: "5 ore", window: five)
                                .frame(maxWidth: .infinity)
                        }
                        if let seven = usage.sevenDay {
                            UsageRing(title: "7 giorni", window: seven)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Pezzi comuni

    private func header(_ title: String, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let count {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .buttonStyle(.plain)
    }

    /// Always shown, fresh or not: a quiet screen because nothing is happening
    /// and a quiet screen because the Mac stopped talking look identical.
    private func freshness(_ snapshot: RemoteSnapshot) -> some View {
        let age = Date().timeIntervalSince(snapshot.generatedAt)
        return HStack(spacing: 5) {
            Image(systemName: age > 120 ? "wifi.exclamationmark" : "checkmark.circle")
            Text("dal Mac \(Format.age(since: snapshot.generatedAt))")
        }
        .font(.caption2)
        .foregroundStyle(age > 120 ? GlowRGB.waiting.color : .white.opacity(0.45))
        .padding(.top, 2)
    }

    /// Accoppiati, ma il Mac non ha ancora pubblicato niente.
    ///
    /// Era una rotella e tre parole, e una rotella che gira per sempre non
    /// spiega nulla: quando manca qualcosa è quasi sempre una di queste due
    /// cose, e sono entrambe sull'altra macchina — dove chi sta guardando il
    /// telefono non è.
    private var waiting: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("In attesa del Mac…")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
            Text("Il Mac deve essere sveglio, e «Pubblica sul relay» acceso nelle impostazioni di Claude Live.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
        }
        .padding(.top, 72)
    }
}

/// Puts the icon after the text instead of before it.
struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.caption2)
        }
    }
}

#Preview("Home") {
    // Dentro una pila di navigazione, che ora serve: le righe dei progetti
    // portano dentro il progetto, e fuori da una pila non porterebbero da nessuna
    // parte.
    NavigationStack {
        ZStack {
            ThemedBackground()
            HomeView(
                snapshot: RemoteSnapshot.sample(now: Date()),
                inFlight: [],
                onDecide: { _, _, _ in },
                onAnswer: { _, _ in },
                onOpenProjects: {},
                onOpenUsage: {}
            )
        }
    }
    .preferredColorScheme(.dark)
}
