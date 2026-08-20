import SwiftUI
import ClaudeLiveKit

/// One permission request, with the buttons that answer it.
///
/// Its own component because it appears in two places — the most urgent one on
/// Home, all of them under Projects — and a decision that looked different in
/// the two would invite the "wait, is this the same one?" hesitation exactly
/// where hesitation is most expensive.
struct PendingDecisionCard: View {
    let session: ClaudeSessionStatus
    let isInFlight: Bool
    let onDecide: (ClaudeSessionStatus, Bool, Bool) -> Void

    @State private var confirmingAlways = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatusDot(state: session.state)
                Text(session.projectName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(Format.age(since: session.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }

            if let tool = session.toolName {
                Text(tool)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(GlowRGB.waiting.color.opacity(0.22), in: Capsule())
            }

            if let summary = session.toolSummary {
                // Not truncated: approving something you cannot read in full is
                // not approving.
                Text(summary)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
            }

            if isInFlight {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("risposta in viaggio…").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } else {
                buttons
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    onDecide(session, true, false)
                } label: {
                    Text("Consenti").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(GlowRGB.done.color)

                Button {
                    onDecide(session, false, false)
                } label: {
                    Text("Nega").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            // Behind a confirmation and visually below the other two, but a
            // button and not a caption. They answer this one request; this one
            // answers every request like it, for good — so it must be reachable
            // without being as easy to hit by reflex.
            Button {
                confirmingAlways = true
            } label: {
                Label("Consenti sempre questo comando", systemImage: "infinity")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.09), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .confirmationDialog(
                "Consentire sempre?",
                isPresented: $confirmingAlways,
                titleVisibility: .visible
            ) {
                Button("Consenti sempre", role: .destructive) {
                    onDecide(session, true, true)
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text(session.toolSummary.map {
                    "D'ora in poi «\($0)» verrà eseguito senza chiedere."
                } ?? "D'ora in poi comandi come questo verranno eseguiti senza chiedere.")
            }
        }
    }
}

#Preview("Decisione") {
    ZStack {
        ThemedBackground()
        VStack(spacing: 16) {
            GlassCard {
                PendingDecisionCard(
                    session: RemoteSnapshot.sample().sessions.first(where: \.isDecidable)!,
                    isInFlight: false,
                    onDecide: { _, _, _ in }
                )
            }
            GlassCard {
                PendingDecisionCard(
                    session: RemoteSnapshot.sample().sessions.first(where: \.isDecidable)!,
                    isInFlight: true,
                    onDecide: { _, _, _ in }
                )
            }
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}
