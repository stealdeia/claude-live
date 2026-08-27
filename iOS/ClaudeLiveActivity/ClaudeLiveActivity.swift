import ActivityKit
import SwiftUI
import WidgetKit
import ClaudeLiveKit

/// L'isola dinamica e la schermata di blocco.
///
/// ## Cos'è questa cosa
///
/// Un bersaglio a sé, che gira in un processo suo: il sistema disegna queste
/// viste quando vuole, anche con l'app chiusa. Il che porta il limite da tenere
/// a mente leggendo il resto del file: **niente animazioni continue**. Le viste
/// vengono disegnate come fotogrammi fermi, quindi la banda di luce che sul Mac
/// scorre dal centro agli estremi qui non può scorrere. Il colore c'è, il
/// movimento no.
///
/// Quello che il sistema *sì* anima è il filo attorno all'isola —
/// `keylineTint` — e quello lo coloriamo con il colore dell'avviso.
@main
struct ClaudeLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        ClaudeLiveActivityWidget()
    }
}

struct ClaudeLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClaudeActivityAttributes.self) { context in
            LockScreenView(state: context.state)
        } dynamicIsland: { context in
            island(for: context.state)
        }
    }

    private func island(for state: ClaudeActivityAttributes.ContentState) -> DynamicIsland {
        DynamicIsland {
            // Aperta: le stesse cose del pannello sul Mac, nello stesso ordine —
            // i due anelli ai lati, il progetto in mezzo, la richiesta in fondo.
            DynamicIslandExpandedRegion(.leading) {
                ActivityRing(
                    title: "5 ore",
                    percent: state.fiveHourPercent,
                    resetsAt: state.fiveHourResetsAt
                )
            }
            DynamicIslandExpandedRegion(.trailing) {
                ActivityRing(
                    title: "7 giorni",
                    percent: state.sevenDayPercent,
                    resetsAt: state.sevenDayResetsAt
                )
            }
            DynamicIslandExpandedRegion(.center) {
                VStack(spacing: 2) {
                    Text(state.projectName ?? "Claude Live")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let label = state.stateLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            DynamicIslandExpandedRegion(.bottom) {
                if let pending = state.pending {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.bubble.fill")
                            .font(.caption2)
                            .foregroundStyle(tint(for: state))
                        Text(pending)
                            .font(.caption2)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }
        } compactLeading: {
            // Chiusa: i due contatori, uno per lato. È quello che si vuole sapere
            // di sfuggita, e l'unica cosa che sta in questo spazio.
            CompactUsage(percent: state.fiveHourPercent, symbol: "clock")
        } compactTrailing: {
            CompactUsage(percent: state.sevenDayPercent, symbol: "calendar")
        } minimal: {
            // Quando l'isola è divisa con un'altra attività resta un pallino: il
            // più urgente dei due numeri, o il colore dell'avviso se ce n'è uno.
            Text(percentLabel(state.fiveHourPercent) ?? "CL")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint(for: state))
        }
        // Il filo che il sistema disegna attorno all'isola: è l'unica cosa che
        // possiamo far brillare là fuori, e prende il colore dell'avviso.
        .keylineTint(tint(for: state))
    }

    private func tint(for state: ClaudeActivityAttributes.ContentState) -> Color {
        state.alert?.defaultColor.color ?? .white
    }

    private func percentLabel(_ percent: Double?) -> String? {
        guard let percent else { return nil }
        return "\(Int(percent.rounded()))"
    }
}

/// Un contatore nello spazio chiuso dell'isola: un simbolo e un numero.
///
/// Senza il segno di percentuale: là dentro ogni carattere è spazio tolto al
/// numero, e «62» accanto a un orologio non si confonde con altro.
private struct CompactUsage: View {
    let percent: Double?
    let symbol: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            if let percent {
                Text("\(Int(percent.rounded()))")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(color)
    }

    /// Lo stesso codice colore degli anelli sul Mac: verde fino a metà, ambra
    /// oltre i tre quarti, rosso vicino al limite.
    private var color: Color {
        guard let percent else { return .white }
        return UsageLevel.level(for: percent / 100, warn: 0.75, danger: 0.9).activityColor
    }
}

/// Un anello con la sua percentuale e il tempo che resta.
///
/// Disegnato qui e non riusato dall'app: la vista dell'app ha animazioni e
/// gradienti che in un widget non vengono eseguiti, e una copia semplice che
/// funziona è meglio di una copia ricca che viene disegnata a metà.
private struct ActivityRing: View {
    let title: String
    let percent: Double?
    let resetsAt: Date?

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: (percent ?? 0) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(percent.map { "\(Int($0.rounded()))" } ?? "–")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: 38, height: 38)

            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            // Il conto alla rovescia lo tiene il sistema: `timer` si aggiorna da
            // sé anche in un widget, che è l'unica animazione concessa qui.
            if let resetsAt, resetsAt > .now {
                Text(resetsAt, style: .timer)
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        guard let percent else { return .white.opacity(0.4) }
        return UsageLevel.level(for: percent / 100, warn: 0.75, danger: 0.9).activityColor
    }
}

/// La schermata di blocco: la stessa sostanza dell'isola aperta, in orizzontale.
///
/// Qui il bordo luminoso possiamo disegnarlo noi, perché questa vista è nostra e
/// non un pezzo dell'isola di sistema. Fermo, non pulsante — resta il limite di
/// prima — ma del colore giusto.
private struct LockScreenView: View {
    let state: ClaudeActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            ActivityRing(
                title: "5 ore",
                percent: state.fiveHourPercent,
                resetsAt: state.fiveHourResetsAt
            )
            ActivityRing(
                title: "7 giorni",
                percent: state.sevenDayPercent,
                resetsAt: state.sevenDayResetsAt
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(state.projectName ?? "Claude Live")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)

                if let label = state.stateLabel {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let pending = state.pending {
                    Text(pending)
                        .font(.caption2)
                        .foregroundStyle(tint)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            // Lo sfondo sfumato del tema, come sul Mac. Il tema scelto nell'app
            // non arriva fin qui — l'estensione è un altro processo e leggerlo
            // vorrebbe dire condividere le preferenze — quindi per ora è quello
            // predefinito, che è anche quello che quasi tutti tengono.
            LinearGradient(
                colors: [ColorTheme.midnight.top, ColorTheme.midnight.deep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .overlay {
            if state.alert != nil {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(tint.opacity(0.75), lineWidth: 2)
            }
        }
    }

    private var tint: Color {
        state.alert?.defaultColor.color ?? .white
    }
}

private extension UsageLevel {
    /// Il colore di questo livello, negli stessi valori del pannello sul Mac.
    var activityColor: Color {
        switch self {
        case .normal: return GlowRGB.done.color
        case .warning: return GlowRGB.waiting.color
        case .danger: return GlowRGB.failed.color
        }
    }
}
