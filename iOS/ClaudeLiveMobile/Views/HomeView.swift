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
    let inFlight: Set<String>
    let onDecide: (ClaudeSessionStatus, Bool, Bool) -> Void
    let onOpenProjects: () -> Void
    let onOpenUsage: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
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
                PendingDecisionCard(
                    session: decidable[0],
                    isInFlight: inFlight.contains(decidable[0].id),
                    onDecide: onDecide
                )
            }

            if decidable.count > 1 {
                Button {
                    onOpenProjects()
                } label: {
                    Label("altre \(decidable.count - 1) da approvare", systemImage: "chevron.right")
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

    private func projects(_ snapshot: RemoteSnapshot) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                header("Progetti", count: snapshot.projects.count, action: onOpenProjects)

                if snapshot.projects.isEmpty {
                    Text("Nessuna sessione aperta")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    VStack(spacing: 9) {
                        ForEach(snapshot.projects, id: \.projectPath) { project in
                            HStack(spacing: 10) {
                                StatusDot(state: project.state, isStale: project.isStale, size: 9)
                                Text((project.projectPath as NSString).lastPathComponent)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(project.state.label)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                    }
                }
            }
        }
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

    private var waiting: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            Text("In attesa del Mac…")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.top, 80)
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
    ZStack {
        ThemedBackground()
        HomeView(
            snapshot: RemoteSnapshot.sample(now: Date()),
            inFlight: [],
            onDecide: { _, _, _ in },
            onOpenProjects: {},
            onOpenUsage: {}
        )
    }
    .preferredColorScheme(.dark)
}
