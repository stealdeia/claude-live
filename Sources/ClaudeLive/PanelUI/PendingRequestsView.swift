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

    private var openQuestions: [ClaudeSessionStatus] {
        status.waitingSessions.filter(\.needsTerminal)
    }

    var body: some View {
        if !decidable.isEmpty || !openQuestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !decidable.isEmpty {
                    section(
                        title: "Da approvare",
                        count: decidable.count,
                        tint: PanelTheme.color(for: .warning)
                    ) {
                        ForEach(decidable) { request in
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
