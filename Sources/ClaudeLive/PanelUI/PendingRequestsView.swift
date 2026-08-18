import SwiftUI

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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(PanelTheme.color(for: .warning))
                    .frame(width: 6, height: 6)

                Text(request.projectName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                if let tool = request.toolName, !tool.isEmpty {
                    Text(tool)
                        .font(.system(size: 8.5, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.10), in: Capsule())
                        .foregroundStyle(PanelTheme.secondaryText)
                }

                Spacer(minLength: 2)
            }

            // What Claude actually wants to do. Without it the buttons would be
            // asking the user to approve something unseen.
            if let summary = request.toolSummary {
                Text(summary)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(PanelTheme.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 5) {
                answerButton("Consenti", tint: PanelTheme.color(for: .normal)) {
                    status.decide(request, allow: true)
                }
                answerButton("Nega", tint: PanelTheme.color(for: .danger)) {
                    status.decide(request, allow: false)
                }
                Spacer(minLength: 2)
                answerButton("Sempre", tint: PanelTheme.secondaryText) {
                    status.decide(request, allow: true, remember: true)
                }
                .help("Consenti ora e non chiedere più per questo comando identico, in questo progetto")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(PanelTheme.color(for: .warning).opacity(isHovering ? 0.16 : 0.10))
        )
        .onHover { isHovering = $0 }
    }

    private func answerButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .foregroundStyle(tint)
                .contentShape(Rectangle())
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
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(PanelTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)

                Spacer(minLength: 2)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
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
