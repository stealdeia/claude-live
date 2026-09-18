import Foundation
import ClaudeLiveKit

/// La modalità dimostrativa: l'app disegnata su dati inventati, per le
/// schermate dell'App Store.
///
/// ## Perché esiste
///
/// Le schermate della scheda vanno guardate da chiunque passi sull'App Store, e
/// quelle vere conterrebbero i nomi dei progetti su cui si stava lavorando, i
/// percorsi del disco con dentro il nome di chi possiede il Mac, e pezzi di
/// conversazioni. Fotografare l'app vera e poi ritoccare i nomi è il modo
/// sicuro di dimenticarne uno: qui non c'è niente da dimenticare, perché non
/// c'è mai stato niente di vero.
///
/// ## Perché non riusa `RemoteSnapshot.sample()`
///
/// Quel campione serve alle anteprime e alle prove, ed è scritto per essere
/// *scomodo* — stati a metà, tempi strani, una sessione ferma da mezz'ora. È
/// giusto per giudicare un disegno e sbagliato per una vetrina, dove serve un
/// momento che si legga in due secondi. E soprattutto nomina progetti veri.
///
/// ## Come si accende
///
/// Solo dall'argomento `-demo` passato al lancio, e solo nelle build di
/// sviluppo: `#if DEBUG` la esclude dal binario che va su App Store Connect,
/// quindi non esiste nessun modo di far mostrare dati finti all'app che la
/// gente installa. `-demo-screen <nome>` sceglie da quale schermata partire.
enum Demo {

    #if DEBUG
    static let isOn = ProcessInfo.processInfo.arguments.contains("-demo")
    #else
    static let isOn = false
    #endif

    /// Da dove parte l'app: `home`, `projects`, `usage`, `chat`, `settings`,
    /// `welcome`, `glow`. Sconosciuta o assente significa `home`.
    static var screen: String {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demo-screen"), i + 1 < args.count else { return "home" }
        return args[i + 1]
    }

    /// `welcome` è l'unica schermata che si vede da non accoppiati, quindi è
    /// l'unica in cui la dimostrazione deve fingere di *non* avere un Mac.
    static var pretendsPaired: Bool { isOn && screen != "welcome" }

    // MARK: - Il momento da mostrare

    /// I nomi sono inventati e i percorsi pure: nessun progetto vero, nessun
    /// nome utente vero. `/Users/demo` e non `/Users/<qualcuno>` perché anche un
    /// nome di cartella è un'informazione su chi possiede il computer.
    private static let shop = "/Users/demo/Progetti/bottega-online"
    private static let weather = "/Users/demo/Progetti/app-meteo"
    private static let payments = "/Users/demo/Progetti/api-pagamenti"
    private static let notes = "/Users/demo/Progetti/diario-corse"

    /// La sessione bloccata su un permesso: è la ragione per cui questa app
    /// esiste, quindi è quella che deve stare in cima alla prima schermata.
    static let blockedSession = "3f9a2c71b4e8"

    /// L'ora della fotografia: adesso, non un istante fissato.
    ///
    /// Un istante fissato renderebbe le immagini identiche a ogni esecuzione, ed
    /// è il primo istinto — ma tutto quello che si legge su queste schermate è
    /// *relativo* a adesso: «ora», «si azzera in 1h 48m», «2 minuti fa». Con una
    /// data ferma, rifare le schermate fra tre mesi darebbe un'app che dice «3
    /// mesi fa» dappertutto e sembra rotta. Costava già: il primo giro è uscito
    /// con «si azzera in 4g 1h» su una finestra di cinque ore, perché la data
    /// scritta qui era avanti rispetto all'orologio vero.
    private static var now: Date { Date() }

    static func snapshot() -> RemoteSnapshot {
        let blocked = ClaudeSessionStatus(json: [
            "project_path": shop,
            "project_name": "bottega-online",
            "session_id": blockedSession,
            "state": "waiting_input",
            "event": "PermissionRequest",
            "request_kind": "permission",
            "request_id": "toolu_demo01",
            "tool_name": "Bash",
            "tool_summary": "npm run build && npm run test",
            "chat_title": "Il carrello perde gli articoli al ricarico",
            "decidable": true,
            "updated_at_epoch": now.timeIntervalSince1970 - 8,
        ])!

        let working = ClaudeSessionStatus(json: [
            "project_path": weather,
            "project_name": "app-meteo",
            "session_id": "8c14d0aa5f23",
            "state": "working",
            "event": "PreToolUse",
            "detail": "Edit",
            "tool_name": "Edit",
            "chat_title": "Le previsioni a sette giorni",
            "decidable": false,
            "updated_at_epoch": now.timeIntervalSince1970 - 3,
        ])!

        let waiting = ClaudeSessionStatus(json: [
            "project_path": payments,
            "project_name": "api-pagamenti",
            "session_id": "5b77e9c31d40",
            "state": "waiting_input",
            "event": "Notification",
            "request_kind": "notification",
            "detail": "Quale dei due approcci preferisci?",
            "chat_title": "I rimborsi parziali",
            "decidable": false,
            "updated_at_epoch": now.timeIntervalSince1970 - 74,
        ])!

        let done = ClaudeSessionStatus(json: [
            "project_path": notes,
            "project_name": "diario-corse",
            "session_id": "c206ab8f7e15",
            "state": "idle",
            "event": "Stop",
            "chat_title": "Il grafico dei chilometri",
            "prompt_request_id": "stop_demo01",
            "decidable": false,
            "updated_at_epoch": now.timeIntervalSince1970 - 420,
        ])!

        return RemoteSnapshot(
            usage: UsageSnapshot(
                fiveHour: UsageWindow(
                    utilization: 0.62,
                    resetAt: now.addingTimeInterval(1 * 3_600 + 48 * 60),
                    status: "allowed"
                ),
                sevenDay: UsageWindow(
                    utilization: 0.34,
                    resetAt: now.addingTimeInterval(3 * 86_400),
                    status: "allowed"
                ),
                opusSevenDay: UsageWindow(
                    utilization: 0.19,
                    resetAt: now.addingTimeInterval(3 * 86_400),
                    status: "allowed"
                ),
                representativeClaim: "five_hour",
                overallStatus: "allowed",
                fetchedAt: now.addingTimeInterval(-12),
                httpStatus: 200,
                subscriptionType: "max"
            ),
            projects: [
                ClaudeProjectStatus(
                    projectPath: shop,
                    state: .waitingInput,
                    detail: "Bash",
                    requestKind: "permission",
                    updatedAt: now.addingTimeInterval(-8),
                    sessionCount: 1,
                    isStale: false
                ),
                ClaudeProjectStatus(
                    projectPath: weather,
                    state: .working,
                    detail: "Edit",
                    requestKind: nil,
                    updatedAt: now.addingTimeInterval(-3),
                    sessionCount: 1,
                    isStale: false
                ),
                ClaudeProjectStatus(
                    projectPath: payments,
                    state: .waitingInput,
                    detail: "Quale dei due approcci preferisci?",
                    requestKind: "notification",
                    updatedAt: now.addingTimeInterval(-74),
                    sessionCount: 1,
                    isStale: false
                ),
                ClaudeProjectStatus(
                    projectPath: notes,
                    state: .idle,
                    detail: nil,
                    requestKind: nil,
                    updatedAt: now.addingTimeInterval(-420),
                    sessionCount: 1,
                    isStale: false
                ),
            ],
            sessions: [blocked, working, waiting, done],
            alert: ClaudeAlert(
                kind: .waiting,
                projectPath: shop,
                projectName: "bottega-online",
                sessionID: blockedSession,
                raisedAt: now.addingTimeInterval(-8),
                detail: "npm run build && npm run test"
            ),
            generatedAt: now,
            messages: [blockedSession: conversation],
            questions: nil
        )
    }

    /// Una conversazione inventata, su un problema che si capisce senza
    /// conoscere il progetto: un carrello che si svuota ricaricando la pagina.
    private static var conversation: [ClaudeMessage] {
        [
            ClaudeMessage(
                author: .assistant,
                text: "Le prove passano tutte e 24. La pagina del prodotto adesso mostra la disponibilità vera invece di «disponibile» fisso.",
                at: now.addingTimeInterval(-2_400)
            ),
            ClaudeMessage(
                author: .user,
                text: "Perfetto. Un'altra cosa: il carrello si svuota quando ricarico la pagina. Riesci a capire perché?",
                at: now.addingTimeInterval(-2_100)
            ),
            ClaudeMessage(
                author: .assistant,
                text: "Trovato. Il carrello vive solo in memoria: `CartStore` lo tiene in una variabile e nessuno lo scrive da nessuna parte, quindi un ricarico riparte da zero.\n\nTi propongo di salvarlo in `localStorage` a ogni cambiamento e rileggerlo all'avvio, con una scadenza di sette giorni perché un carrello di un mese fa non è più una cosa che qualcuno vuole ritrovare.",
                at: now.addingTimeInterval(-1_800)
            ),
            ClaudeMessage(
                author: .user,
                text: "Va bene. Aggiungi anche una prova che il carrello sopravvive al ricarico.",
                at: now.addingTimeInterval(-900)
            ),
            ClaudeMessage(
                author: .assistant,
                text: "Fatto: `CartStore` adesso legge e scrive, e la prova ricrea lo store da zero e verifica che ritrovi i tre articoli.\n\nProvo a compilare e a far girare le prove.",
                at: now.addingTimeInterval(-20)
            ),
        ]
    }
}
