import CryptoKit
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
/// ## Perché i widget stanno in questo bersaglio e non in uno nuovo
///
/// Questo è già un `WidgetBundle` sotto `com.apple.widgetkit-extension`: è
/// esattamente il punto d'estensione che vogliono anche i widget della schermata
/// Home e di StandBy. Un bersaglio nuovo avrebbe voluto un terzo identificativo
/// di pacchetto, un terzo file di autorizzazioni, un terzo profilo di firma e una
/// terza coppia di numeri di versione — che `tools/release-ios.sh` **pretende**
/// concordi con le altre due, e che è già andata di traverso una volta. Più la
/// riga `embed: true`, la cui assenza il 2026-08-27 mandò su TestFlight una build
/// senza l'isola dentro.
///
/// Tre superfici, tre `Widget` distinti e non uno che si adatta: in StandBy iOS
/// accetta **solo** `systemSmall`, e due slot affiancati possono mostrare due
/// widget diversi. Un widget unico avrebbe potuto occupare un solo slot, e là
/// dentro i due contatori e l'elenco dei progetti non ci stanno insieme.
@main
struct ClaudeLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        ClaudeLiveActivityWidget()
        UsageWidget()
        ProjectsWidget()
        OverviewWidget()
    }
}

struct ClaudeLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClaudeActivityAttributes.self) { context in
            let state = Self.resolve(context.state, context.attributes)
            LockScreenView(state: state, trouble: Self.trouble(context.state, context.attributes))
                .widgetURL(Self.homeLink)
        } dynamicIsland: { context in
            let state = Self.resolve(context.state, context.attributes)
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
        _ state: ClaudeActivityAttributes.ContentState,
        _ attributes: ClaudeActivityAttributes
    ) -> ClaudeIslandState {
        // In chiaro: l'app sta parlando a se stessa, non c'è niente da aprire.
        if let island = state.island { return island }

        // Sigillato: è arrivato per notifica, e va aperto con la chiave che l'app
        // ha copiato nel gruppo condiviso.
        if let sealed = state.sealed, let key = key(from: attributes),
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
        _ state: ClaudeActivityAttributes.ContentState,
        _ attributes: ClaudeActivityAttributes
    ) -> String? {
        if state.island != nil { return nil }
        guard state.sealed != nil else { return "vuoto" }
        // Col numero: «chiave» da sola non distingue i modi in cui può mancare,
        // e sono guasti con cure diverse. È così che abbiamo scoperto il -25291.
        guard key(from: attributes) != nil else { return "chiave \(IslandKey.lookupStatus())" }
        return nil
    }

    /// La chiave per aprire le scatole: prima il portachiavi, poi l'attività.
    ///
    /// In quest'ordine perché il portachiavi è il posto giusto per un segreto, e
    /// se un giorno tornasse raggiungibile da qui va usato lui. Ma da questa
    /// estensione oggi risponde «nessun portachiavi disponibile», quindi la
    /// chiave viaggia anche dentro l'attività — dove il sistema la consegna
    /// insieme al resto, senza che nessun processo debba andarsela a prendere.
    static func key(from attributes: ClaudeActivityAttributes) -> SymmetricKey? {
        if let stored = IslandKey.read() { return stored }
        guard let text = attributes.key else { return nil }
        return try? RemoteCrypto.importKey(text)
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
            // Un pallino solo, e conta più di quanto sembri: è la presentazione
            // che l'isola usa quando è divisa con un'altra attività, **ed è anche
            // l'unica cosa che iOS mostra in StandBy** — un piccolo indicatore in
            // cima allo schermo che, toccato, apre la vista della schermata di
            // blocco ingrandita di 2×. Cioè è la porta per la Live Activity a
            // schermo pieno, non una scoria.
            //
            // Lo stato e non la percentuale, cambiato il 2026-09-08 dopo averlo
            // visto sul telefono. Qui c'era il numero delle 5 ore, che dentro
            // l'isola divisa ha un senso — sta accanto al resto — ma da solo in
            // mezzo a uno schermo in StandBy è «11», e nessuno può indovinare
            // undici di cosa. Un simbolo invece dice la cosa per cui ci si
            // alzerebbe dalla sedia: campanella se qualcuno aspetta, ingranaggio
            // se sta lavorando, spunta se è tutto fermo.
            Image(systemName: Self.urgentState(state).symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(minimalTint(for: state))
        }
        // Il filo che il sistema disegna attorno all'isola: è l'unica cosa che
        // possiamo far brillare là fuori, e prende il colore dell'avviso.
        .keylineTint(tint(for: state))
    }

    private func tint(for state: ClaudeIslandState) -> Color {
        state.alert?.defaultColor.color ?? .white
    }

    /// Lo stato più urgente fra i progetti, per il pallino che li riassume tutti.
    ///
    /// `max()` e non un confronto scritto a mano: `ClaudeActivity` è già
    /// `Comparable` per urgenza — attende input, poi errore, poi al lavoro, poi
    /// in attesa — ed è la stessa graduatoria con cui il Mac ordina il pannello.
    /// Senza progetti è «fermo», che è la verità.
    static func urgentState(_ state: ClaudeIslandState) -> ClaudeActivity {
        state.projects.map(\.state).max() ?? .idle
    }

    /// Il colore del pallino: quello dell'avviso se ce n'è uno in corso, quello
    /// dello stato altrimenti.
    ///
    /// In quest'ordine perché un avviso è un fatto appena accaduto — «ha finito»,
    /// «si è interrotto» — mentre lo stato è una condizione che dura, e quando
    /// c'è il primo è lui la notizia.
    private func minimalTint(for state: ClaudeIslandState) -> Color {
        state.alert?.defaultColor.color ?? Self.urgentState(state).tint
    }
}

/// Un progetto: il pallino del suo stato, il nome, e cosa sta facendo.
///
/// Interna e non privata: la usano l'isola, la schermata di blocco **e** i
/// widget. Il colore lo dà `ClaudeActivity.tint` dal pacchetto condiviso — prima
/// era mappato qui a mano, con la giustificazione che «la vista che li tiene vive
/// nell'app e un widget non può dipendere dall'app». Vera la premessa, sbagliata
/// la conclusione: la mappatura è salita nel pacchetto, che entrambi possono
/// leggere, invece di essere copiata una terza volta.
struct ProjectLine: View {
    let project: ClaudeIslandState.Project
    let tint: Color

    /// Quanto ingrandire, per le superfici guardate da lontano — StandBy, e i
    /// widget grandi. A 1 la riga è identica a com'era nell'isola.
    var scale: CGFloat = 1

    /// Se mettere anche il simbolo dello stato accanto al pallino.
    ///
    /// Serve dove il colore non arriva: in StandBy notturno iOS disegna i widget
    /// in modalità `vibrant`, che riduce tutto a un'unica tinta. Là il pallino
    /// verde e quello ambra diventano lo stesso pallino, e senza simbolo la riga
    /// dice il nome di un progetto e nient'altro.
    var showsSymbol: Bool = false

    /// Se dire anche *cosa* sta facendo, oltre a chi è.
    ///
    /// Spento nel quadrato piccolo dei widget: là «progetto-molto-lungo» e «al
    /// lavoro» si contendono la stessa riga, e il risultato è che si tronca il
    /// nome — cioè l'unica delle due cose che non si può indovinare dal colore.
    var showsState: Bool = true

    var body: some View {
        HStack(spacing: 6 * scale) {
            if showsSymbol {
                Image(systemName: project.state.symbol)
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundStyle(project.alerting ? tint : project.state.tint)
                    .frame(width: 12 * scale)
            } else {
                // Dentro una cornice più alta del cerchio: un cerchio che riempie
                // esattamente la sua riga è il primo a perdere un pezzo quando
                // qualcosa taglia dall'alto.
                Circle()
                    .fill(project.alerting ? tint : project.state.tint)
                    .frame(width: 7 * scale, height: 7 * scale)
                    .frame(width: 10 * scale, height: 14 * scale)
            }
            Text(project.name)
                .font(.system(size: 11 * scale, weight: project.alerting ? .semibold : .regular))
                .lineLimit(1)
            if showsState {
                Text(project.state.label)
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 14 * scale)
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
///
/// ## Tutto discende dal diametro
///
/// Le misure erano fisse — tratto 4, diciture 12, 11 e 9 — perché servivano a un
/// solo posto. Ora servono a quattro, di cui due guardati **da lontano**: lo slot
/// StandBy e la Live Activity a schermo pieno, che iOS disegna in una cornice
/// molto più larga. Un anello grande con la dicitura di prima non è un anello
/// grande, è un anello con dentro una scritta minuscola.
///
/// I fattori sono scelti perché a `diameter = 44` restituiscano esattamente i
/// numeri di prima: l'isola non cambia di un pixel.
struct ActivityRing: View {
    /// «5h» o «7g»: la finestra, non il suo nome per esteso.
    let label: String
    let percent: Double?
    let resetsAt: Date?

    /// Nell'isola aperta lo spazio è quello che è, e il tempo che manca è la cosa
    /// meno urgente delle tre.
    var showsReset: Bool = true

    var diameter: CGFloat = 44

    private var lineWidth: CGFloat { diameter * 0.0909 }

    var body: some View {
        VStack(spacing: diameter * 0.045) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: (percent ?? 0) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(label)
                    .font(.system(size: diameter * 0.273, weight: .semibold))
            }
            .frame(width: diameter, height: diameter)

            Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(.system(size: diameter * 0.25, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)

            if showsReset, let resetsAt {
                Text(Format.resetDelay(until: resetsAt))
                    .font(.system(size: diameter * 0.205))
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
/// ## Due presentazioni, una vista
///
/// Questa vista compare in due posti molto diversi. Sulla schermata di blocco è
/// una scheda larga circa 340 punti, **con un tetto di 160 punti d'altezza** —
/// oltre quello il sistema taglia. In StandBy, telefono in carica e in
/// orizzontale, iOS la mette nella presentazione `minimal` in cima allo schermo e
/// quando la si tocca la porta a schermo pieno: là il tetto non c'è.
///
/// A distinguerle è `isActivityFullscreen`, da iOS 18. Senza quella chiave le due
/// presentazioni sono indistinguibili dall'interno, e l'unica scelta possibile
/// sarebbe una misura sola buona per entrambe — che vuol dire una scheda
/// sproporzionata sulla schermata di blocco, o metà schermo nero in StandBy.
///
/// ## Come si comporta lo scaling, misurato
///
/// iOS ingrandisce **2×** questa vista nella presentazione a schermo pieno, e la
/// larghezza la impone lui mentre l'altezza segue il contenuto. Contato sul
/// telefono il 2026-09-08: 96 punti di contenuto diventavano una scheda alta 186
/// su 393 di schermo, cioè metà schermo nero. Quindi per riempirlo non si tocca
/// una scala — si fa crescere l'altezza **intrinseca**, e il 2× fa il resto.
///
/// ## Cosa ho sbagliato prima, lo stesso giorno
///
/// Il primo tentativo era un `GeometryReader` che ricavava la scala dalla
/// larghezza disponibile. Sbagliato due volte: inutile, perché il 2× lo applica
/// già il sistema, e dannoso, perché un `GeometryReader` **non ha dimensione
/// propria** — si prende lo spazio proposto senza dichiararne nessuno. Il
/// sistema, che a questa vista deve *chiedere* quanto è alta, non riceveva più
/// risposta e le dava il minimo: la scheda sulla schermata di blocco si è
/// ristretta e i conti alla rovescia finivano tagliati.
///
/// Poi l'ho rifatto, lo stesso giorno e con un altro vestito: un `Spacer` dentro
/// la colonna verticale, per appoggiare l'elenco in alto invece di lasciarlo
/// galleggiare. Un `Spacer` è **infinitamente elastico** lungo l'asse del suo
/// contenitore, quindi quella colonna ha smesso di dichiarare un'altezza e ha
/// cominciato a dire «alta quanto vuoi». Stavolta non si è ristretta: l'attività
/// **non è più comparsa affatto**, isola dinamica compresa.
///
/// ## La regola, visto che è servita due volte
///
/// In una Live Activity ogni cosa nella gerarchia deve avere una dimensione
/// intrinseca, perché è il sistema a chiederla per dimensionare la scheda.
/// Niente `GeometryReader`, niente `Spacer` sull'asse verticale, niente
/// `maxHeight: .infinity`. La scala qui sotto è un **numero** e non una misura
/// letta da una cornice: è per questo che è ammessa.
///
/// Lo `Spacer(minLength: 0)` orizzontale in fondo all'`HStack` invece resta, e
/// non è un'incoerenza: la larghezza la impone il sistema, quindi su quell'asse
/// non c'è niente da dichiarare.
private struct LockScreenView: View {
    let state: ClaudeIslandState

    /// Perché i numeri non sono freschi, quando non lo sono. Vedi `trouble`.
    var trouble: String?

    /// StandBy notturno: iOS abbassa la luminanza e vira tutto al rosso scuro.
    /// Là dentro un elenco completo di progetti con le date di azzeramento è
    /// rumore illeggibile; restano i due numeri e chi sta aspettando.
    @Environment(\.isLuminanceReduced) private var dimmed

    /// Se siamo nella presentazione a schermo pieno — in pratica: StandBy, dopo
    /// che si è toccato l'indicatore in cima.
    @Environment(\.isActivityFullscreen) private var fullscreen

    /// Quante righe di progetto stanno a schermo pieno.
    ///
    /// Quante righe di progetto stanno a schermo pieno.
    ///
    /// Tre, e stavolta il numero viene da una misura invece che da una stima: la
    /// colonna del testo ha ~93 punti d'altezza, il titolo ne prende 18 e ogni
    /// riga 18. Gli altri sono contati in una riga: la quarta farebbe tagliare
    /// la scheda, che è il modo peggiore di perdere un progetto — senza dirlo.
    private static let fullscreenRowLimit = 3

    var body: some View {
        content
        .background {
            // Lo sfondo sfumato del tema scelto nell'app. Prima era `.midnight`
            // scritto a mano, con la ragione giusta — «l'estensione è un altro
            // processo e leggere le preferenze vorrebbe dire condividerle» — e
            // ora che il deposito condiviso esiste, condividerle è quello che
            // facciamo.
            LinearGradient(
                colors: [SharedStore.theme.top, SharedStore.theme.deep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .overlay {
            // Solo sulla schermata di blocco, dove la scheda **è** la mia vista
            // e il filo ne segna il bordo.
            //
            // A schermo pieno no, e non per gusto: là il sistema aggiunge un
            // margine proprio attorno alla vista, quindi il filo segnava i
            // confini del *contenuto* e galleggiava dentro la scheda, staccato
            // dai bordi su tutti i lati — si leggeva come un rettangolo verde
            // disegnato dentro, non come il bordo di qualcosa. Quei margini non
            // li decidiamo noi e non c'è modo di combaciarci: `ContainerRelativeShape`
            // l'ho provata e la Live Activity è sparita, perché nella stessa
            // build c'era anche lo `Spacer` che l'ha rotta — ma provarla di
            // nuovo non risolverebbe comunque il margine del sistema.
            //
            // Non si perde l'avviso: là il titolo è già del colore dell'avviso,
            // e il progetto che lo riguarda ha il pallino colorato.
            if state.alert != nil, !fullscreen {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(tint.opacity(0.75), lineWidth: 2)
            }
        }
    }

    private var content: some View {
        // Schermo pieno: anelli da 62 e testo a 1,3. Il contenuto sta a ~117
        // punti sui ~136 concessi, e dei 365 di larghezza ne restano ~199 alla
        // colonna del testo — abbastanza perché «trasferimento in attesa» non si
        // tronchi, che è il difetto del tentativo a 1,8.
        //
        // Schermata di blocco: invariata. Là il tetto è 160 e questa ne usa 96.
        fullscreen
            ? layout(ring: 62, headlineSize: 17, troubleSize: 11,
                     rowScale: 1.3, padding: 12,
                     rowLimit: Self.fullscreenRowLimit, showsState: false)
            : layout(ring: 44, headlineSize: 13, troubleSize: 9,
                     rowScale: 1, padding: 14, rowLimit: nil, showsState: true)
    }

    /// ## Una forma, due tarature
    ///
    /// Anelli a sinistra, elenco a destra, in entrambe le presentazioni: sono la
    /// stessa forma, e tenerne due in pari era lavoro che si paga senza comprare
    /// niente. Cambiano solo i numeri.
    ///
    /// I numeri, **misurati** il 2026-09-08 sul telefono invece di essere
    /// dedotti da una fotografia come le tre volte precedenti:
    ///
    /// - **Schermata di blocco**: cornice ~340 punti di larghezza, tetto **160**
    ///   d'altezza oltre il quale il sistema taglia. Questa taratura ne usa 96.
    /// - **Schermo pieno in StandBy**: cornice **365** punti, ingrandita **2×**
    ///   dal sistema. E il tetto non è mezzo schermo: iOS si tiene ~120 punti di
    ///   margine proprio — 66 sopra, 55 sotto — quindi dei 393 dello schermo
    ///   restano ~273, cioè **~136 intrinsechi**.
    ///
    /// Quei 136 sono il vero motivo per cui «facciamola più grande» ha un
    /// limite, e il pezzo che mancava a tutte le stime: a 144 la scheda veniva
    /// tagliata sopra e sotto.
    ///
    /// ## E la larghezza è più stretta di quanto sembri
    ///
    /// Dei 365 punti, alla colonna del testo ne arrivano **179**: gli anelli ne
    /// prendono 124 e le due spaziature dell'`HStack` altri 36 — una delle due
    /// me l'ero persa, contandone 199. In 179 punti «trasferimento» *più* «in
    /// attesa» non ci stanno, e il nome si troncava.
    ///
    /// La cura non è rimpicciolire gli anelli: anche a 54 punti la somma non
    /// torna. È che `showsState` a schermo pieno è **spento**. Lo stato in
    /// parole costa ~68 punti dei 179 — più di un terzo — per ripetere «in
    /// attesa» su ogni riga, mentre il pallino lo dice già col colore. Da
    /// lontano il nome è il segnale e lo stato è il colore; un nome troncato non
    /// è né l'uno né l'altro.
    private func layout(
        ring: CGFloat,
        headlineSize: CGFloat,
        troubleSize: CGFloat,
        rowScale: CGFloat,
        padding: CGFloat,
        rowLimit: Int?,
        showsState: Bool
    ) -> some View {
        HStack(spacing: 14 * rowScale) {
            ActivityRing(
                label: "5h",
                percent: state.fiveHourPercent,
                resetsAt: state.fiveHourResetsAt,
                showsReset: !dimmed,
                diameter: ring
            )
            ActivityRing(
                label: "7g",
                percent: state.sevenDayPercent,
                resetsAt: state.sevenDayResetsAt,
                showsReset: !dimmed,
                diameter: ring
            )

            VStack(alignment: .leading, spacing: 3 * rowScale) {
                // Accanto agli anelli, non scagliato a destra. Nel tentativo di
                // prima fra i due c'era uno `Spacer`, che a schermo pieno
                // spingeva il titolo contro il bordo opposto con duecento punti
                // di vuoto in mezzo: su una scheda larga e bassa non c'è niente
                // da distribuire, c'è da stare vicini.
                headline(size: headlineSize, troubleSize: troubleSize)

                // Tutti, dove ci stanno: questa è una scheda a tutta larghezza,
                // non i centoventi punti dell'isola aperta.
                //
                // A luminanza ridotta solo quelli che stanno aspettando: in
                // StandBy notturno lo schermo è appena acceso, e un elenco intero
                // di righe grigie non si legge comunque.
                ForEach(rows(limit: rowLimit)) { project in
                    // Toccare un nome porta a quel progetto. Prima la schermata
                    // di blocco aveva un solo collegamento per tutto.
                    projectRow(project, scale: rowScale, showsState: showsState)
                }

                if let hidden = hiddenCount(limit: rowLimit), hidden > 0 {
                    Text("+\(hidden) altri")
                        .font(.system(size: 11 * rowScale))
                        .foregroundStyle(.secondary)
                }

                pendingLine(size: 11 * rowScale)
            }

            Spacer(minLength: 0)
        }
        .padding(padding)
    }

    private func rows(limit: Int?) -> [ClaudeIslandState.Project] {
        guard let limit else { return visibleProjects }
        return Array(visibleProjects.prefix(limit))
    }

    private func hiddenCount(limit: Int?) -> Int? {
        guard let limit else { return nil }
        return max(0, visibleProjects.count - limit)
    }

    // La sonda che ha dato quei numeri non c'è più: ha finito il suo lavoro, e
    // i numeri stanno scritti sopra.
    //
    // Era un `GeometryReader` dentro un `overlay(alignment: .topTrailing)` che
    // disegnava «larghezza×altezza» in piccolo, sotto `#if DEBUG`. Se un giorno
    // servisse rimisurare — un iPhone di un'altra dimensione, una versione di
    // iOS che cambia i margini — sono tre righe e vanno rimesse **così**:
    // nell'overlay e non nell'impaginazione, perché l'overlay viene dimensionato
    // *dal* contenuto e legge la misura senza poterla influenzare. Un
    // `GeometryReader` che partecipa all'impaginazione rompe la Live Activity.
    //
    // Cosa ha detto, il 2026-09-08 su iPhone 14 Pro con iOS 26.6.1: **364×125**
    // a schermo pieno, contro un tetto di ~141. Le tre stime che l'avevano
    // preceduta dicevano 196, e sbagliavano tutte per lo stesso motivo — nessuna
    // teneva conto dei ~55 punti di margine che iOS si tiene per lato.

    // MARK: - Pezzi comuni alle due impaginazioni

    private func headline(size: CGFloat, troubleSize: CGFloat) -> some View {
        HStack(spacing: 5) {
            Text(state.headline)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(state.alert == nil ? .primary : tint)
                .lineLimit(1)
            if let trouble {
                // Piccola e grigia: non è un avviso per l'utente, è una traccia
                // per capire. Compare solo quando qualcosa non ha funzionato, e
                // allora vale più di uno schermo muto.
                Text(trouble)
                    .font(.system(size: troubleSize))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func projectRow(
        _ project: ClaudeIslandState.Project,
        scale: CGFloat,
        showsState: Bool
    ) -> some View {
        Link(destination: ClaudeLiveActivityWidget.link(toProject: project)) {
            ProjectLine(project: project, tint: tint, scale: scale, showsState: showsState)
        }
    }

    @ViewBuilder
    private func pendingLine(size: CGFloat) -> some View {
        if let pending = state.pending {
            Link(destination: ClaudeLiveActivityWidget.link(toWaitingChat: state)) {
                Text(pending)
                    .font(.system(size: size))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var visibleProjects: [ClaudeIslandState.Project] {
        guard dimmed else { return state.projects }
        let waiting = state.projects.filter { $0.state == .waitingInput || $0.alerting }
        // Se non c'è nessuno in attesa restano i due primi, che sono i più
        // urgenti: la fotografia arriva già ordinata per urgenza dal Mac.
        return waiting.isEmpty ? Array(state.projects.prefix(2)) : waiting
    }

    private var tint: Color {
        state.alert?.defaultColor.color ?? .white
    }

}

extension UsageLevel {
    /// Il colore di questo livello, negli stessi valori del pannello sul Mac.
    ///
    /// Interna e non privata da quando la leggono anche i widget: era `private`
    /// perché la usava solo questo file.
    var activityColor: Color {
        switch self {
        case .normal: return GlowRGB.done.color
        case .warning: return GlowRGB.waiting.color
        case .danger: return GlowRGB.failed.color
        }
    }
}
