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
            let state = Self.resolve(context.state)
            LockScreenView(state: state)
                .widgetURL(Self.link(for: state))
        } dynamicIsland: { context in
            let state = Self.resolve(context.state)
            return island(for: state)
                .widgetURL(Self.link(for: state))
        }
    }

    /// Il contenuto da disegnare, aperto se era sigillato.
    ///
    /// Un aggiornamento che arriva per notifica è cifrato: il relay lo trasporta
    /// senza poterlo leggere, e la chiave sta nel portachiavi condiviso con
    /// l'app. Se manca — l'app non è mai stata aperta da quando esiste questa
    /// versione, o l'accoppiamento è stato rifatto — si mostra un'isola spoglia,
    /// che è meglio di una che mente.
    static func resolve(
        _ state: ClaudeActivityAttributes.ContentState
    ) -> ClaudeIslandState {
        if let island = state.island { return island }
        guard let sealed = state.sealed,
              let key = IslandKey.read(),
              let opened = try? RemoteCrypto.open(ClaudeIslandState.self, from: sealed, with: key)
        else { return ClaudeIslandState() }
        return opened
    }

    /// Dove porta il tocco su una riga: quel progetto.
    static func link(toProject project: ClaudeIslandState.Project) -> URL {
        var parts = URLComponents()
        parts.scheme = "claudelive"
        parts.host = "project"
        parts.queryItems = [URLQueryItem(name: "path", value: project.path)]
        return parts.url ?? URL(string: "claudelive://open")!
    }

    /// Dove porta il tocco: la chat dell'avviso, o l'app.
    ///
    /// Uno schema tutto suo e non un indirizzo web: deve aprire *questa* app,
    /// anche se il telefono non ha rete.
    static func link(for state: ClaudeIslandState) -> URL? {
        if let session = state.alertSessionID, !session.isEmpty {
            return URL(string: "claudelive://chat/\(session)")
        }
        return URL(string: "claudelive://open")
    }

    private func island(for state: ClaudeIslandState) -> DynamicIsland {
        DynamicIsland {
            // Aperta: le stesse cose del pannello sul Mac, nello stesso ordine —
            // i due anelli ai lati, il progetto in mezzo, la richiesta in fondo.
            DynamicIslandExpandedRegion(.leading) {
                ActivityRing(
                    label: "5h",
                    percent: state.fiveHourPercent,
                    resetsAt: state.fiveHourResetsAt,
                    showsReset: false,
                    diameter: 40
                )
            }
            DynamicIslandExpandedRegion(.trailing) {
                ActivityRing(
                    label: "7g",
                    percent: state.sevenDayPercent,
                    resetsAt: state.sevenDayResetsAt,
                    showsReset: false,
                    diameter: 40
                )
            }
            DynamicIslandExpandedRegion(.center) {
                Text(state.headline)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.alert == nil ? .primary : tint(for: state))
                    .lineLimit(1)
            }
            DynamicIslandExpandedRegion(.bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(state.projects) { project in
                        // Ogni riga porta al *suo* progetto, non alla schermata
                        // iniziale: se l'isola mostra tre nomi, toccarne uno deve
                        // portare a quello che si è toccato.
                        Link(destination: Self.link(toProject: project)) {
                            ProjectLine(project: project, tint: tint(for: state))
                        }
                    }

                    if let pending = state.pending {
                        Text(pending)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    // Nessun pulsante per rispondere, di proposito: la risposta si
                    // dà nell'app, dove si vede anche la conversazione. Qui basta
                    // una porta, e tutta l'isola è quella porta.
                    if state.alert != nil {
                        HStack(spacing: 4) {
                            Text("Tocca per aprire")
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint(for: state))
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

    private func tint(for state: ClaudeIslandState) -> Color {
        state.alert?.defaultColor.color ?? .white
    }

    private func percentLabel(_ percent: Double?) -> String? {
        guard let percent else { return nil }
        return "\(Int(percent.rounded()))"
    }
}

/// Un progetto: il pallino del suo stato, il nome, e cosa sta facendo.
///
/// Il pallino usa i colori del pannello sul Mac, mappati qui a mano: la vista
/// che li tiene vive nell'app, e un widget non può dipendere dall'app.
private struct ProjectLine: View {
    let project: ClaudeIslandState.Project
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(project.alerting ? tint : color)
                .frame(width: 7, height: 7)
            Text(project.name)
                .font(.caption2.weight(project.alerting ? .semibold : .regular))
                .lineLimit(1)
            Text(project.state.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        // Il pallino veniva tagliato in cima: senza un'altezza dichiarata la riga
        // si stringe su quella del testo, e il cerchio sporge.
        .frame(minHeight: 16)
    }

    private var color: Color {
        switch project.state {
        case .waitingInput: return GlowRGB.waiting.color
        case .error: return GlowRGB.failed.color
        case .working: return GlowRGB.done.color
        case .idle, .unknown: return .secondary
        }
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

/// Un anello: la finestra dentro, la percentuale sotto, e — dove c'è spazio —
/// quanto manca all'azzeramento.
///
/// La dicitura sta **dentro** il cerchio come sul Mac, e non sotto: nel cerchio
/// c'è spazio e sotto no, e un numero sotto un cerchio vuoto non dice di cosa
/// sia la percentuale.
///
/// Disegnato qui e non riusato dall'app: la vista dell'app ha animazioni e
/// gradienti che in un widget non vengono eseguiti, e una copia semplice che
/// funziona è meglio di una ricca disegnata a metà.
private struct ActivityRing: View {
    /// «5h» o «7g»: la finestra, non il suo nome per esteso.
    let label: String
    let percent: Double?
    let resetsAt: Date?

    /// Nell'isola aperta lo spazio è quello che è, e il tempo che manca è la cosa
    /// meno urgente delle tre.
    var showsReset: Bool = true

    var diameter: CGFloat = 44

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: (percent ?? 0) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(width: diameter, height: diameter)

            Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)

            if showsReset, let resetsAt {
                Text(Format.resetDelay(until: resetsAt))
                    .font(.system(size: 9))
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
    let state: ClaudeIslandState

    var body: some View {
        HStack(spacing: 14) {
            ActivityRing(
                label: "5h",
                percent: state.fiveHourPercent,
                resetsAt: state.fiveHourResetsAt
            )
            ActivityRing(
                label: "7g",
                percent: state.sevenDayPercent,
                resetsAt: state.sevenDayResetsAt
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(state.headline)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(state.alert == nil ? .primary : tint)
                    .lineLimit(1)

                ForEach(state.projects) { project in
                    ProjectLine(project: project, tint: tint)
                }

                if let pending = state.pending {
                    Text(pending)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
