import SwiftUI
import ClaudeLiveKit

/// The whole app, in one screen.
///
/// One screen and not a tab bar: there are three things to show and they are all
/// short. Splitting them across tabs would mean the answer to "does anything
/// need me?" lives behind a tap, which is the one question this app exists to
/// answer instantly.
struct DashboardView: View {
    let snapshot: RemoteSnapshot?
    /// Nil while nothing has arrived yet; a message when the last attempt failed.
    let problem: String?
    let inFlight: Set<String>
    let onDecide: (ClaudeSessionStatus, Bool, Bool) -> Void
    let onRefresh: () async -> Void
    var onOpenSettings: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let problem {
                        problemBanner(problem)
                    }

                    if let snapshot {
                        // Requests first: on a phone this is why the app was opened.
                        PendingRequestsView(
                            sessions: snapshot.sessions,
                            inFlight: inFlight,
                            onDecide: onDecide
                        )

                        if let usage = snapshot.usage {
                            UsageBarsView(usage: usage)
                        }

                        ProjectsListView(
                            projects: snapshot.projects,
                            sessions: snapshot.sessions,
                            highlightedSessionID: snapshot.alert?.sessionID
                        )

                        staleness(snapshot)
                    } else if problem == nil {
                        waiting
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(.background.tertiary)
            .navigationTitle("Claude Live")
            .refreshable { await onRefresh() }
            .toolbar {
                if let onOpenSettings {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onOpenSettings()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Impostazioni")
                    }
                }
            }
        }
    }

    // MARK: - Pezzi di contorno

    private func problemBanner(_ message: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(GlowRGB.waiting.color)
            Text(message)
                .font(.footnote)
            Spacer()
        }
        .padding(12)
        .background(GlowRGB.waiting.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var waiting: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("In attesa del Mac…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// How old the picture is, said plainly at the bottom.
    ///
    /// A snapshot that stopped arriving looks exactly like one where nothing is
    /// happening — both are a quiet screen. The only thing that tells them apart
    /// is this line, which is why it is always shown and never hidden when fresh.
    private func staleness(_ snapshot: RemoteSnapshot) -> some View {
        let age = Date().timeIntervalSince(snapshot.generatedAt)
        return HStack(spacing: 5) {
            Image(systemName: age > 120 ? "wifi.exclamationmark" : "checkmark.circle")
            Text("dal Mac \(Format.age(since: snapshot.generatedAt))")
        }
        .font(.caption2)
        .foregroundStyle(age > 120 ? GlowRGB.waiting.color : .secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}

#Preview("Con richieste") {
    DashboardView(
        snapshot: RemoteSnapshot.sample(now: Date()),
        problem: nil,
        inFlight: [],
        onDecide: { _, _, _ in },
        onRefresh: {}
    )
}

#Preview("Tutto tranquillo") {
    DashboardView(
        snapshot: RemoteSnapshot.sampleQuiet(now: Date()),
        problem: nil,
        inFlight: [],
        onDecide: { _, _, _ in },
        onRefresh: {}
    )
}

#Preview("Mac non raggiungibile") {
    DashboardView(
        snapshot: RemoteSnapshot.sample(now: Date().addingTimeInterval(-900)),
        problem: "Il Mac non risponde da 15 minuti.",
        inFlight: [],
        onDecide: { _, _, _ in },
        onRefresh: {}
    )
}

#Preview("Primo avvio") {
    DashboardView(
        snapshot: nil,
        problem: nil,
        inFlight: [],
        onDecide: { _, _, _ in },
        onRefresh: {}
    )
}
