import SwiftUI
import ClaudeLiveKit

/// What Claude is waiting on, split the way the Mac splits it — and for the same
/// functional reason, not for tidiness.
///
/// *Da approvare* are requests whose hook is actually blocked, so Consenti and
/// Nega lead somewhere. *Domande aperte* are everything else: real questions
/// that only the terminal can answer, where offering a button would be a lie.
///
/// On the phone this sits at the top, unlike the Mac where usage comes first.
/// The reason is the reason you opened the app: a notification said Claude wants
/// something, and the answer to "what?" should not require scrolling.
struct PendingRequestsView: View {
    let sessions: [ClaudeSessionStatus]
    /// Ids currently being sent, so a button cannot be pressed twice.
    let inFlight: Set<String>
    let onDecide: (ClaudeSessionStatus, Bool, Bool) -> Void

    private var decidable: [ClaudeSessionStatus] { sessions.filter(\.isDecidable) }
    private var questions: [ClaudeSessionStatus] { sessions.filter(\.needsTerminal) }

    var body: some View {
        if !decidable.isEmpty || !questions.isEmpty {
            VStack(spacing: 14) {
                if !decidable.isEmpty {
                    SectionCard(title: "Da approvare") {
                        VStack(spacing: 14) {
                            ForEach(decidable) { session in
                                decidableRow(session)
                                if session.id != decidable.last?.id { Divider() }
                            }
                        }
                    }
                }

                if !questions.isEmpty {
                    SectionCard(title: "Domande aperte", subtitle: "solo dal terminale") {
                        VStack(spacing: 12) {
                            ForEach(questions) { session in
                                questionRow(session)
                            }
                        }
                    }
                }
            }
        }
    }

    private func decidableRow(_ session: ClaudeSessionStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(state: session.state)
                Text(session.projectName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(Format.age(since: session.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let tool = session.toolName {
                Text(tool)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(GlowRGB.waiting.color.opacity(0.18), in: Capsule())
            }

            if let summary = session.toolSummary {
                // The command itself, monospaced and not truncated to one line:
                // this is what is being approved, and approving something you
                // cannot fully read is not approving.
                Text(summary)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
            }

            if inFlight.contains(session.id) {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("invio…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 8) {
                    Button("Consenti") { onDecide(session, true, false) }
                        .buttonStyle(.borderedProminent)
                    Button("Nega") { onDecide(session, false, false) }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Sempre") { onDecide(session, true, true) }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                }
                .controlSize(.regular)
            }
        }
    }

    private func questionRow(_ session: ClaudeSessionStatus) -> some View {
        HStack(spacing: 10) {
            StatusDot(state: session.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName)
                    .font(.subheadline)
                Text(session.activityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(Format.age(since: session.updatedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("In attesa") {
    ScrollView {
        PendingRequestsView(
            sessions: RemoteSnapshot.sample().sessions,
            inFlight: [],
            onDecide: { _, _, _ in }
        )
        .padding()
    }
    .background(.background.tertiary)
}

#Preview("Invio in corso") {
    let snapshot = RemoteSnapshot.sample()
    return ScrollView {
        PendingRequestsView(
            sessions: snapshot.sessions,
            inFlight: Set(snapshot.sessions.filter(\.isDecidable).map(\.id)),
            onDecide: { _, _, _ in }
        )
        .padding()
    }
    .background(.background.tertiary)
}
