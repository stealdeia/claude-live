import SwiftUI
import WidgetKit
import ClaudeLiveKit

/// I widget della schermata Home e degli slot StandBy.
///
/// ## Cosa possono e cosa non possono
///
/// Un widget **non è live**, e non può diventarlo: iOS decide lui quando
/// ridisegnarlo, con un budget che in pratica vale una ricarica ogni quindici o
/// venti minuti. Non esiste un modo di chiedere «aggiornati ogni cinque
/// secondi», e nessuna quantità di codice qui dentro lo cambia.
///
/// Questo decide tutto il resto del file. Un widget che finge di essere in tempo
/// reale mente il 95% del tempo; quindi ognuno di questi mostra **quanto è
/// vecchio il suo dato**, e sbiadisce da sé quando quel dato invecchia troppo —
/// la stessa scelta che la Live Activity fa con la sua `staleDate`.
///
/// ## Da dove prendono il contenuto
///
/// Due strade, e la seconda è la rete di sicurezza della prima.
///
/// **L'app deposita.** Quando gira — anche svegliata in sottofondo da una
/// notifica silenziosa — decifra la fotografia e lascia il contenuto in chiaro
/// nel contenitore condiviso; il widget lo legge. È la strada veloce, e finché
/// funziona è anche la migliore: in un processo a cui il sistema concede poco
/// tempo e poca memoria, «leggo un file» ha molti meno modi di fallire di «apro
/// una connessione e decifro».
///
/// **Il widget se lo va a prendere.** Perché la prima strada ha un buco che è
/// costato una giornata di widget fermi: iOS **non consegna** le notifiche
/// silenziose a un'app tolta dal multitasking o mai aperta dopo un riavvio.
/// Quando succede nessuno deposita più niente, e i widget ridisegnano per ore lo
/// stesso numero senza che nulla, da nessuna parte, sia rotto. Quindi prima di
/// disegnarsi il widget prova a leggere il relay da sé, con la chiave del
/// portachiavi.
///
/// Non sostituisce le notifiche, mette un pavimento sotto di loro: la ricarica di
/// un widget ha un budget che iOS decide, in pratica una ogni quindici o venti
/// minuti. Le notifiche restano la corsia veloce quando l'app è raggiungibile.
///
/// ## Il portachiavi da qui risponde, ed è una notizia
///
/// Per settimane il codice ha detto il contrario: da questa estensione il
/// portachiavi rispondeva `-25291`, «nessun portachiavi disponibile», misurato
/// sul telefono — ed è il motivo per cui la chiave dell'isola viaggia dentro
/// `ClaudeActivityAttributes`, che un widget non ha.
///
/// Quel fallimento veniva da `IslandKey.accessGroup()`, che per scoprire il
/// prefisso **scriveva** una voce di prova sul percorso di lettura. Quando
/// `read()` è stato riscritto per cercare senza dichiarare il gruppo il guasto è
/// sparito con lui, ma nessuno aveva rimisurato e la conclusione vecchia è
/// rimasta scritta in quattro punti diversi, dove ha continuato a dire che
/// questa strada era chiusa.
///
/// **Rimisurato il 2026-09-09**, su iPhone 14 Pro, con una sonda che stampava
/// l'esito in fondo al riquadro: `chiave OK` con l'app aperta, e `chiave OK`
/// anche ad app terminata e Live Activity rimosse. Poi la catena intera —
/// `relay letto OK`, cioè fotografia scaricata e aperta dall'estensione, senza
/// che l'app girasse.
///
/// Se un giorno dovesse tornare a non rispondere, il widget ricade sul deposito
/// come prima e scrive il numero in fondo al riquadro: `-34018` autorizzazione,
/// `-25300` voce assente, `-25308` telefono mai sbloccato.

// MARK: - La linea temporale

/// Un istante da disegnare: il contenuto, e **quando** lo si sta guardando.
///
/// La data non è decorativa. È lei che permette alla scritta «dal Mac 4 min fa»
/// di avanzare senza che nessuno ricarichi niente: la linea temporale contiene
/// più voci con lo stesso contenuto e date diverse, e iOS passa dall'una all'altra
/// da sé. Senza, un widget che non riceve aggiornamenti mostrerebbe «ora» per
/// mezz'ora.
struct IslandEntry: TimelineEntry {
    let date: Date
    let island: ClaudeIslandState?

    /// Perché il contenuto manca, quando manca. Da `SharedStore.diagnosis()`.
    let trouble: String?

    /// Da quanto il dato non si rinnova, guardato adesso.
    var age: TimeInterval {
        guard let island else { return 0 }
        return date.timeIntervalSince(island.updatedAt)
    }

    /// Oltre questo, il widget si disegna smorzato invece di far credere che i
    /// numeri siano di adesso.
    ///
    /// Venticinque minuti, gli stessi della `staleDate` della Live Activity, e
    /// per la stessa ragione scritta là: il Mac rimanda il contenuto ogni otto
    /// minuti anche se identico, quindi venticinque sopravvive a una notifica
    /// persa senza arrivare a mentire quando il Mac è spento davvero.
    var isStale: Bool { age > 25 * 60 }

    /// Dove porta un tocco che non ha centrato niente in particolare.
    ///
    /// Sulla richiesta in attesa, se ce n'è una: è la sola cosa in questi widget
    /// su cui ci sia davvero qualcosa da fare, e chi tocca un riquadro che dice
    /// «1 in attesa» sta chiedendo di vedere *quella*. Altrimenti la schermata
    /// iniziale, che è la stessa scelta che l'isola fa per lo spazio vuoto: chi
    /// tocca là si aspetta di aprire l'app, non di finire in una conversazione.
    var fallbackLink: URL {
        guard let island, island.pending != nil else {
            return ClaudeLiveActivityWidget.homeLink
        }
        return ClaudeLiveActivityWidget.link(toWaitingChat: island)
    }

    /// La riga in fondo: cosa non va, o quanto è vecchio il dato.
    var footnote: String {
        if let trouble { return trouble }
        guard let island else { return "nessun dato" }
        // «dal Mac», come in `HomeView`: dice in una parola *di chi* è il dato,
        // che su una superficie staccata dall'app è la metà che manca.
        return "dal Mac \(Format.age(since: island.updatedAt, now: date))"
    }
}

struct IslandProvider: TimelineProvider {

    func placeholder(in context: Context) -> IslandEntry {
        IslandEntry(
            date: Date(),
            island: ClaudeIslandState(snapshot: .sample()),
            trouble: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (IslandEntry) -> Void) {
        // Nella galleria dei widget non c'è ancora niente da mostrare di vero, e
        // un riquadro vuoto non fa capire a cosa serva: là dentro va l'esempio.
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        completion(current(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IslandEntry>) -> Void) {
        Task {
            let refusal = await Self.fetchForOurselves()
            completion(Self.timeline(at: Date(), refusal: refusal))
        }
    }

    /// Prova a rinnovare il deposito senza passare dall'app. Restituisce il
    /// motivo per cui non ci è riuscito, o `nil` se ce l'ha fatta.
    ///
    /// Non ricarica le linee temporali: siamo *dentro* la loro costruzione, e
    /// chiederne una qui sarebbe un anello chiuso che si mangia il budget.
    private static func fetchForOurselves() async -> String? {
        // Se il deposito è appena stato rinnovato, non c'è niente da andare a
        // prendere. Succede tutte le volte che è l'app a chiedere la ricarica:
        // ha appena scritto lei, e una lettura in più sarebbe rete e batteria
        // spese per riottenere gli stessi numeri.
        if let stored = SharedStore.read(),
           Date().timeIntervalSince(stored.updatedAt) < 2 * 60 {
            return nil
        }
        guard let coordinates = SharedStore.relayCoordinates else {
            return "apri l'app una volta"
        }
        guard let key = IslandKey.read() else {
            // Il numero, non la parola: `-34018` è un'autorizzazione mancante,
            // `-25300` una voce mai scritta, `-25308` un telefono mai sbloccato
            // dopo il riavvio. Tre cure diverse dietro lo stesso riquadro muto.
            return "chiave \(IslandKey.lookupStatus())"
        }
        do {
            let fresh = try await RemoteFetcher.snapshot(
                relayURL: coordinates.url,
                pairID: coordinates.pairID,
                key: key,
                // Corto di proposito: meglio un widget che si disegna con il dato
                // di prima che uno che non si disegna perché stava aspettando.
                timeout: 8
            )
            SharedStore.write(ClaudeIslandState(snapshot: fresh))
            return nil
        } catch {
            return "relay non raggiungibile"
        }
    }

    private static func timeline(at now: Date, refusal: String?) -> Timeline<IslandEntry> {
        let island = SharedStore.read()

        // Cosa scrivere in fondo, in ordine di quanto è utile saperlo.
        //
        // Il rifiuto viene **prima** della diagnosi del deposito, e non dopo come
        // avevo scritto: se il deposito è vuoto, `diagnosis()` dice «apri l'app
        // una volta» — che è vero ma è il sintomo — mentre il rifiuto dice perché
        // non siamo riusciti a rimediare da soli, che è la causa e l'unica delle
        // due su cui si possa intervenire.
        //
        // E quando il deposito è fresco non si scrive niente: l'app sta facendo
        // il suo lavoro, *come* ci siamo arrivati non interessa a nessuno, e là
        // sotto serve l'età del dato — l'unica cosa che un widget debba sempre
        // dire di sé.
        let trouble: String?
        if let island {
            let stale = now.timeIntervalSince(island.updatedAt) > 25 * 60
            trouble = stale ? refusal : nil
        } else {
            trouble = refusal ?? SharedStore.diagnosis()
        }

        // Lo stesso contenuto a distanza di tempo: le voci future non dicono
        // cose nuove, fanno **invecchiare** quella presente sotto gli occhi di
        // chi guarda. È il solo modo onesto di essere una superficie che iOS
        // ridisegna quando vuole.
        let entries = [0, 5, 15, 30].map { minutes in
            IslandEntry(
                date: now.addingTimeInterval(Double(minutes) * 60),
                island: island,
                trouble: trouble
            )
        }

        // Un quarto d'ora: chiedere più spesso non ottiene più spesso — il budget
        // è quello — e chiedere meno spesso rinuncerebbe a un aggiornamento che il
        // sistema avrebbe concesso. È anche la cadenza con cui il widget rilegge
        // il relay da sé, visto che è qui che ripassa.
        //
        // Chi tiene il passo *davvero*, quando può, resta la notifica silenziosa:
        // ricarica queste linee temporali nell'istante in cui c'è qualcosa di
        // nuovo, invece di aspettare il prossimo giro.
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60)))
    }

    private func current(at date: Date) -> IslandEntry {
        IslandEntry(date: date, island: SharedStore.read(), trouble: SharedStore.diagnosis())
    }
}

// MARK: - I tre widget

/// I due contatori. Il widget da mettere nello slot StandBy di sinistra.
struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "it.aldeialab.ClaudeLive.usage", provider: IslandProvider()) { entry in
            UsageWidgetView(entry: entry)
                .widgetURL(entry.fallbackLink)
                .claudeWidgetChrome()
        }
        .configurationDisplayName("Utilizzo")
        .description("Quanto è consumato delle finestre di 5 ore e 7 giorni.")
        // `systemSmall` non è opzionale: è l'unica famiglia che iOS accetta
        // negli slot StandBy, e StandBy è il motivo per cui questo widget esiste.
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// I progetti e cosa stanno facendo. Lo slot StandBy di destra.
struct ProjectsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "it.aldeialab.ClaudeLive.projects", provider: IslandProvider()) { entry in
            ProjectsWidgetView(entry: entry)
                // Anche sul medio e sul grande, dove ogni riga è già un
                // collegamento: le righe coprono le righe, non l'intestazione né
                // il margine, e un tocco là finirebbe nel vuoto.
                .widgetURL(entry.fallbackLink)
                .claudeWidgetChrome()
        }
        .configurationDisplayName("Progetti")
        .description("Le sessioni di Claude Code: al lavoro, in attesa, o ferme.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Tutto insieme, per chi ha spazio sulla schermata Home.
struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "it.aldeialab.ClaudeLive.overview", provider: IslandProvider()) { entry in
            OverviewWidgetView(entry: entry)
                .widgetURL(entry.fallbackLink)
                .claudeWidgetChrome()
        }
        .configurationDisplayName("Panoramica")
        .description("I due contatori e i progetti, in un riquadro grande.")
        .supportedFamilies([.systemLarge])
    }
}

// MARK: - Lo sfondo

private extension View {
    /// Lo sfondo sfumato del tema scelto nell'app, e il tema scuro imposto.
    ///
    /// ## Lo sfondo
    ///
    /// `containerBackground` e non un `.background`, e la differenza conta: negli
    /// slot StandBy e sulla schermata di blocco iOS **rimuove** lo sfondo del
    /// contenitore da sé, per far sembrare il contenuto appoggiato sullo schermo.
    /// Uno sfondo disegnato a mano resterebbe là come un rettangolo colorato in
    /// mezzo al nero.
    ///
    /// ## Perché il tema scuro va imposto
    ///
    /// Un widget prende l'aspetto **di sistema**, non quello dell'app.
    /// `RootView` forza `preferredColorScheme(.dark)`, ma quella riga vale solo
    /// dentro l'app: qui non arriva. Quindi con il telefono in modalità chiara
    /// `.primary` e `.secondary` si risolvevano in **nero**, sopra questo sfondo
    /// che è scuro sempre — scritte invisibili sulla schermata Home, mentre in
    /// StandBy si vedevano benissimo perché là è scuro comunque. Visto il
    /// 2026-09-08.
    ///
    /// Imposto e non adattato: lo sfondo di questa app è un gradiente
    /// nero-verso-colore e non ne esiste una versione chiara — è la stessa
    /// ragione per cui `RootView` lo forza. Un widget che schiarisse lo sfondo
    /// sarebbe un altro widget.
    ///
    /// Sotto `containerBackground` di proposito: in modalità `vibrant` — StandBy
    /// notturno — iOS rifà i colori a suo modo, e questa riga non gli toglie
    /// niente perché agisce sui colori semantici prima che lui li rimpiazzi.
    func claudeWidgetChrome() -> some View {
        environment(\.colorScheme, .dark)
            .containerBackground(for: .widget) {
                LinearGradient(
                    colors: [SharedStore.theme.top, SharedStore.theme.deep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
    }
}

// MARK: - Utilizzo

private struct UsageWidgetView: View {
    let entry: IslandEntry

    @Environment(\.widgetFamily) private var family

    /// Falso in StandBy e sulla schermata di blocco: iOS ha togliato lo sfondo
    /// del contenitore, cioè siamo su una superficie guardata da più lontano.
    /// Non esiste un modo diretto di chiedere «sono in StandBy?», e questa è
    /// l'informazione che serve davvero — più grande, non «StandBy».
    @Environment(\.showsWidgetContainerBackground) private var framed

    var body: some View {
        Group {
            if family == .systemMedium { medium } else { small }
        }
        .opacity(entry.isStale ? 0.55 : 1)
    }

    private var small: some View {
        GeometryReader { geometry in
            // Ricavato e non scritto: fra un quadrato sulla schermata Home e uno
            // slot StandBy ci sono parecchi punti di differenza, e due misure
            // fisse sarebbero una giusta e una sbagliata.
            let diameter = min(geometry.size.width * 0.40, geometry.size.height * 0.50)
            VStack(spacing: 8) {
                HStack(spacing: diameter * 0.30) {
                    // Il conto alla rovescia solo dove c'è spazio. Nel quadrato
                    // sulla schermata Home ruba altezza agli anelli, e «fra
                    // quanto si azzera» è la meno urgente delle tre cose; nello
                    // slot StandBy, che è più grande, ci sta.
                    ring("5h", entry.island?.fiveHourPercent, entry.island?.fiveHourResetsAt,
                         diameter, showsReset: !framed)
                    ring("7g", entry.island?.sevenDayPercent, entry.island?.sevenDayResetsAt,
                         diameter, showsReset: !framed)
                }
                footnote
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var medium: some View {
        HStack(spacing: 18) {
            // Qui no, e non per spazio: il conto alla rovescia c'è già nella
            // colonna di destra, per esteso e con l'ora. Due volte lo stesso dato
            // in un riquadro largo 360 punti è una delle due di troppo.
            ring("5h", entry.island?.fiveHourPercent, entry.island?.fiveHourResetsAt,
                 62, showsReset: false)
            ring("7g", entry.island?.sevenDayPercent, entry.island?.sevenDayResetsAt,
                 62, showsReset: false)

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.island?.headline ?? "Vibing Code Live")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                resetLine("5 ore", entry.island?.fiveHourResetsAt)
                resetLine("7 giorni", entry.island?.sevenDayResetsAt)
                Spacer(minLength: 0)
                footnote
            }
            Spacer(minLength: 0)
        }
    }

    private func ring(
        _ label: String,
        _ percent: Double?,
        _ resetsAt: Date?,
        _ diameter: CGFloat,
        showsReset: Bool
    ) -> some View {
        ActivityRing(
            label: label,
            percent: percent,
            resetsAt: resetsAt,
            showsReset: showsReset,
            diameter: diameter
        )
    }

    private func resetLine(_ title: String, _ resetsAt: Date?) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let resetsAt {
                Text("· \(Format.resetDelay(until: resetsAt))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .lineLimit(1)
    }

    private var footnote: some View {
        Text(entry.footnote)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

// MARK: - Progetti

private struct ProjectsWidgetView: View {
    let entry: IslandEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.showsWidgetContainerBackground) private var framed

    /// In StandBy notturno iOS disegna i widget in modalità `vibrant`: un'unica
    /// tinta, i colori appiattiti. Là il pallino di stato non distingue più
    /// niente, e serve il simbolo.
    @Environment(\.widgetRenderingMode) private var rendering

    /// Quante righe stanno, per famiglia. Il piccolo ne prende meno di quante
    /// entrerebbero: tre righe leggibili valgono più di cinque schiacciate.
    private var rowLimit: Int {
        switch family {
        case .systemLarge: return 5
        case .systemMedium: return 4
        default: return framed ? 3 : 4
        }
    }

    private var projects: [ClaudeIslandState.Project] {
        Array((entry.island?.projects ?? []).prefix(rowLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 5 : 7) {
            header
            if projects.isEmpty {
                Text("Nessuna sessione aperta.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(projects) { project in
                    row(project)
                }
            }
            Spacer(minLength: 0)
            if family == .systemLarge, let island = entry.island, let pending = island.pending {
                Link(destination: ClaudeLiveActivityWidget.link(toWaitingChat: island)) {
                    Text(pending)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Text(entry.footnote)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(entry.isStale ? 0.55 : 1)
    }

    @ViewBuilder
    private func row(_ project: ClaudeIslandState.Project) -> some View {
        let line = ProjectLine(
            project: project,
            tint: entry.island?.alert?.defaultColor.color ?? .white,
            scale: framed ? 1 : 1.25,
            showsSymbol: rendering != .fullColor,
            showsState: family != .systemSmall
        )
        if family == .systemSmall {
            // Nel quadrato piccolo le righe **non** sono collegamenti: là dentro
            // sono troppo vicine perché un tocco possa scegliere fra loro con
            // sicurezza, e aprire il progetto sbagliato è peggio che aprire
            // l'app. Ci pensa il collegamento su tutto il riquadro.
            line
        } else {
            Link(destination: ClaudeLiveActivityWidget.link(toProject: project)) { line }
        }
    }

    /// Cosa c'è da sapere prima dei nomi: quanti stanno aspettando una risposta.
    ///
    /// È il numero per cui ci si alza dalla sedia, quindi va prima e colorato.
    /// «Progetti» come titolo direbbe soltanto cosa sono le righe sotto, cosa che
    /// si vede già.
    private var header: some View {
        let all = entry.island?.projects ?? []
        let waiting = all.filter { $0.state == .waitingInput }.count
        let working = all.filter { $0.state == .working }.count

        let text: String
        let color: Color
        let symbol: String
        if waiting > 0 {
            text = waiting == 1 ? "1 in attesa" : "\(waiting) in attesa"
            color = ClaudeActivity.waitingInput.tint
            symbol = ClaudeActivity.waitingInput.symbol
        } else if working > 0 {
            text = working == 1 ? "1 al lavoro" : "\(working) al lavoro"
            color = ClaudeActivity.working.tint
            symbol = ClaudeActivity.working.symbol
        } else {
            text = all.isEmpty ? "Vibing Code Live" : "tutto fermo"
            color = .secondary
            symbol = ClaudeActivity.idle.symbol
        }

        return HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
    }
}

// MARK: - Panoramica

private struct OverviewWidgetView: View {
    let entry: IslandEntry

    @Environment(\.widgetRenderingMode) private var rendering

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                ActivityRing(
                    label: "5h",
                    percent: entry.island?.fiveHourPercent,
                    resetsAt: entry.island?.fiveHourResetsAt,
                    diameter: 58
                )
                ActivityRing(
                    label: "7g",
                    percent: entry.island?.sevenDayPercent,
                    resetsAt: entry.island?.sevenDayResetsAt,
                    diameter: 58
                )
                Spacer(minLength: 0)
                Text(entry.island?.headline ?? "Vibing Code Live")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(entry.island?.alert?.defaultColor.color ?? .primary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }

            Divider().overlay(.white.opacity(0.12))

            if (entry.island?.projects ?? []).isEmpty {
                Text("Nessuna sessione di Claude Code aperta.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entry.island?.projects ?? []) { project in
                    Link(destination: ClaudeLiveActivityWidget.link(toProject: project)) {
                        ProjectLine(
                            project: project,
                            tint: entry.island?.alert?.defaultColor.color ?? .white,
                            scale: 1.15,
                            showsSymbol: rendering != .fullColor
                        )
                    }
                }
            }

            Spacer(minLength: 0)

            if let island = entry.island, let pending = island.pending {
                Link(destination: ClaudeLiveActivityWidget.link(toWaitingChat: island)) {
                    Text(pending)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Text(entry.footnote)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(entry.isStale ? 0.55 : 1)
    }
}

// MARK: - Anteprime

private let sampleEntry = IslandEntry(
    date: Date(timeIntervalSince1970: 1_787_000_060),
    island: ClaudeIslandState(snapshot: .sample()),
    trouble: nil
)

private let emptyEntry = IslandEntry(date: Date(), island: nil, trouble: "apri l'app una volta")

#Preview("Utilizzo · piccolo", as: .systemSmall) {
    UsageWidget()
} timeline: {
    sampleEntry
    emptyEntry
}

#Preview("Utilizzo · medio", as: .systemMedium) {
    UsageWidget()
} timeline: {
    sampleEntry
}

#Preview("Progetti · piccolo", as: .systemSmall) {
    ProjectsWidget()
} timeline: {
    sampleEntry
}

#Preview("Progetti · medio", as: .systemMedium) {
    ProjectsWidget()
} timeline: {
    sampleEntry
}

#Preview("Panoramica", as: .systemLarge) {
    OverviewWidget()
} timeline: {
    sampleEntry
}
