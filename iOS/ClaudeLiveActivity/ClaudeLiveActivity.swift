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
            LockScreenView(state: state, trouble: Self.trouble(context.state))
                .widgetURL(Self.homeLink)
        } dynamicIsland: { context in
            let state = Self.resolve(context.state)
            return island(for: state)
                .widgetURL(Self.homeLink)
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
        // In chiaro: l'app sta parlando a se stessa, non c'è niente da aprire.
        if let island = state.island { return island }

        // Sigillato: è arrivato per notifica, e va aperto con la chiave che l'app
        // ha copiato nel gruppo condiviso.
        if let sealed = state.sealed,
           let key = IslandKey.read(),
           let opened = try? RemoteCrypto.open(ClaudeIslandState.self, from: sealed, with: key) {
            return opened
        }

        // Non si è aperta. Prima qui c'era `ClaudeIslandState()` — un'isola
        // vuota, cioè i trattini, senza alcun modo di sapere perché: la chiave
        // assente, la chiave sbagliata e una notifica senza contenuto finivano
        // tutte e tre nello stesso schermo muto.
        //
        // Meglio l'ultimo numero letto: dice ancora qualcosa di vero, e la
        // scadenza lo fa sbiadire da sé se invecchia troppo.
        if let remembered = IslandKey.lastGood() { return remembered }
        return ClaudeIslandState()
    }

    /// Perché l'isola non sta mostrando dati freschi, se non li sta mostrando.
    ///
    /// Una parola sola, disegnata piccola al posto dei numeri. Non è rifinitura:
    /// i trattini sono comparsi quattro volte e ogni volta abbiamo tirato a
    /// indovinare, perché tre guasti diversi producevano lo stesso schermo. Alla
    /// prossima volta basterà guardare.
    static func trouble(
        _ state: ClaudeActivityAttributes.ContentState
    ) -> String? {
        if state.island != nil { return nil }
        guard state.sealed != nil else { return "vuoto" }
        guard IslandKey.read() != nil else { return "chiave" }
        return nil
    }

    /// Dove porta il tocco su una riga: quel progetto.
    static func link(toProject project: ClaudeIslandState.Project) -> URL {
        var parts = URLComponents()
        parts.scheme = "claudelive"
        parts.host = "project"
        parts.queryItems = [URLQueryItem(name: "path", value: project.path)]
        return parts.url ?? URL(string: "claudelive://open")!
    }

    /// Dove porta il tocco «da altre parti»: la schermata iniziale.
    ///
    /// Non la chat dell'avviso, che era la scelta di prima: le righe dei progetti
    /// e la richiesta hanno un collegamento loro, e tutto il resto — lo spazio
    /// vuoto, gli anelli, il titolo — non promette niente in particolare. Chi
    /// tocca là si aspetta di aprire l'app, non di finire in una conversazione.
    ///
    /// Uno schema tutto suo e non un indirizzo web: deve aprire *questa* app,
    /// anche se il telefono non ha rete.
    static let homeLink = URL(string: "claudelive://open")!

    /// La chat che sta aspettando, per il collegamento sulla richiesta.
    static func link(toWaitingChat state: ClaudeIslandState) -> URL {
        guard let session = state.alertSessionID, !session.isEmpty else { return homeLink }
        return URL(string: "claudelive://chat/\(session)") ?? homeLink
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
                    diameter: 34
                )
            }
            DynamicIslandExpandedRegion(.trailing) {
                ActivityRing(
                    label: "7g",
                    percent: state.sevenDayPercent,
                    resetsAt: state.sevenDayResetsAt,
                    showsReset: false,
                    diameter: 34
                )
            }
            DynamicIslandExpandedRegion(.center) {
                Text(state.headline)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.alert == nil ? .primary : tint(for: state))
                    .lineLimit(1)
            }
            DynamicIslandExpandedRegion(.bottom) {
                // Poco, perché l'isola aperta ha un'altezza massima decisa da
                // iOS e ciò che sfora viene **tagliato**, non compresso: con tre
                // progetti, la richiesta su due righe e una scritta «tocca per
                // aprire», il primo pallino veniva mozzato in cima. La cura è
                // togliere, non chiedere più spazio.
                //
                // Due progetti e non tre: qui è l'anteprima, l'elenco intero sta
                // nell'app e sulla schermata di blocco, che ha più aria. E niente
                // scritta «tocca per aprire»: ogni riga è già un collegamento, e
                // dirlo costava esattamente la riga che mancava.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.projects.prefix(2)) { project in
                        Link(destination: Self.link(toProject: project)) {
                            ProjectLine(project: project, tint: tint(for: state))
                        }
                    }

                    if let pending = state.pending {
                        // La richiesta porta alla chat che la sta aspettando: è
                        // l'unica cosa qui che ha un posto preciso dove andare.
                        Link(destination: Self.link(toWaitingChat: state)) {
                            Text(pending)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        } compactLeading: {
            // Chiusa: i due contatori, uno per lato. È quello che si vuole sapere
            // di sfuggita, e l'unica cosa che sta in questo spazio.
            CompactUsage(percent: state.fiveHourPercent, label: "5h")
        } compactTrailing: {
            CompactUsage(percent: state.sevenDayPercent, label: "7g")
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
            // Dentro una cornice più alta del cerchio: un cerchio che riempie
            // esattamente la sua riga è il primo a perdere un pezzo quando
            // qualcosa taglia dall'alto.
            Circle()
                .fill(project.alerting ? tint : color)
                .frame(width: 7, height: 7)
                .frame(width: 10, height: 14)
            Text(project.name)
                .font(.caption2.weight(project.alerting ? .semibold : .regular))
                .lineLimit(1)
            Text(project.state.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 14)
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

    /// «5h» o «7g»: quale finestra è questo numero.
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            // La dicitura, non un'icona. Un orologio e un calendario dicono
            // «tempo» e «giorni» a chi già sa cosa sta guardando, e niente a
            // chiunque altro: «5h» e «7g» lo dicono a tutti, e occupano meno.
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(percent.map { "\(Int($0.rounded()))" } ?? "–")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
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

    /// Perché i numeri non sono freschi, quando non lo sono. Vedi `trouble`.
    var trouble: String?

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

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(state.headline)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(state.alert == nil ? .primary : tint)
                        .lineLimit(1)
                    if let trouble {
                        // Piccola e grigia: non è un avviso per l'utente, è una
                        // traccia per capire. Compare solo quando qualcosa non
                        // ha funzionato, e allora vale più di uno schermo muto.
                        Text(trouble)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }

                // Tutti, non due: questa è una scheda a tutta larghezza sulla
                // schermata di blocco, non i centoventi punti dell'isola aperta.
                // È qui che l'elenco dei progetti ha senso di esistere.
                ForEach(state.projects) { project in
                    // Anche qui, non solo nell'isola aperta: toccare un nome
                    // porta a quel progetto. Prima la schermata di blocco aveva
                    // un solo collegamento per tutto.
                    Link(destination: ClaudeLiveActivityWidget.link(toProject: project)) {
                        ProjectLine(project: project, tint: tint)
                    }
                }

                if let pending = state.pending {
                    Link(destination: ClaudeLiveActivityWidget.link(toWaitingChat: state)) {
                        Text(pending)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
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
