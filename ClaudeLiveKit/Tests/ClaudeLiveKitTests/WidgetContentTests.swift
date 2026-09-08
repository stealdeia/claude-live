import XCTest
@testable import ClaudeLiveKit

/// Le due regole che i widget hanno reso necessarie, provate senza un telefono.
///
/// Sono le sole due parti di questo lavoro che contengano una decisione invece di
/// un disegno: il resto — anelli, righe, scale — si giudica guardandolo, e da qui
/// non c'è modo di guardarlo. Queste due invece si possono sbagliare in silenzio,
/// ed è esattamente quello che facevano prima.
final class WidgetContentTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - «È cambiato qualcosa?»

    /// Il caso per cui la funzione esiste: due contenuti identici, letti a un
    /// minuto di distanza.
    ///
    /// Con `==` la risposta sarebbe «diversi», perché `updatedAt` è diverso — e
    /// da quella risposta dipendono una notifica dal Mac e una ricarica dei
    /// widget, cioè due bilanci che iOS e Apple concedono con parsimonia.
    func testOraDiversaStessoContenuto() {
        let island = ClaudeIslandState(
            fiveHourPercent: 42,
            sevenDayPercent: 17,
            projects: [.init(name: "hub", path: "/a/hub", state: .working, alerting: false)],
            updatedAt: now
        )
        var later = island
        later.updatedAt = now.addingTimeInterval(60)

        XCTAssertNotEqual(island, later, "l'ora è comunque parte dell'uguaglianza normale")
        XCTAssertTrue(island.describesSameContent(as: later))
    }

    /// Simmetrica, perché le due sponde la chiamano in ordini opposti: il Mac
    /// chiede «la nuova è come l'ultima spedita», il telefono «quella in deposito
    /// è come la nuova».
    func testSimmetrica() {
        let a = ClaudeIslandState(fiveHourPercent: 10, updatedAt: now)
        var b = a
        b.updatedAt = now.addingTimeInterval(600)

        XCTAssertEqual(a.describesSameContent(as: b), b.describesSameContent(as: a))
    }

    /// Ogni campo che il widget disegna deve poter far scattare un aggiornamento.
    /// Un campo dimenticato qui è un widget che non si muove più quando quel
    /// campo cambia — e non c'è niente, sullo schermo, che lo dica.
    func testOgniCampoContaDavvero() {
        let base = ClaudeIslandState(
            fiveHourPercent: 42,
            fiveHourResetsAt: now,
            sevenDayPercent: 17,
            sevenDayResetsAt: now,
            projects: [.init(name: "hub", path: "/a/hub", state: .working, alerting: false)],
            alertSessionID: "s1",
            alertKind: "waiting",
            pending: "posso scrivere?",
            updatedAt: now
        )

        var percent = base; percent.fiveHourPercent = 43
        var reset = base; reset.sevenDayResetsAt = now.addingTimeInterval(3600)
        var stato = base
        stato.projects = [.init(name: "hub", path: "/a/hub", state: .waitingInput, alerting: false)]
        var nome = base
        nome.projects = [.init(name: "altro", path: "/a/hub", state: .working, alerting: false)]
        var avviso = base; avviso.alertKind = "done"
        var attesa = base; attesa.pending = "posso cancellare?"
        var vuoto = base; vuoto.projects = []

        for (nomeDelCaso, diverso) in [
            ("percentuale", percent),
            ("azzeramento", reset),
            ("stato del progetto", stato),
            ("nome del progetto", nome),
            ("tipo di avviso", avviso),
            ("richiesta in attesa", attesa),
            ("nessun progetto", vuoto),
        ] {
            XCTAssertFalse(
                base.describesSameContent(as: diverso),
                "\(nomeDelCaso): un cambiamento qui non farebbe aggiornare il widget"
            )
        }
    }

    // MARK: - L'ordine dei progetti

    private func project(
        _ path: String,
        _ state: ClaudeActivity,
        _ updatedAt: Date
    ) -> ClaudeProjectStatus {
        ClaudeProjectStatus(
            projectPath: path,
            state: state,
            detail: nil,
            requestKind: nil,
            updatedAt: updatedAt,
            sessionCount: 1,
            isStale: false
        )
    }

    /// L'urgenza viene prima di tutto: è il motivo per cui si guarda il widget.
    func testUrgenzaPrimaDiTutto() {
        let sorted = ClaudeProjectStatus.sortedByUrgency([
            project("/a", .idle, now),
            project("/b", .waitingInput, now.addingTimeInterval(-3600)),
            project("/c", .working, now),
        ])

        XCTAssertEqual(sorted.map(\.projectPath), ["/b", "/c", "/a"])
    }

    /// A pari urgenza decide chi si è mosso per ultimo.
    func testAPariUrgenzaIlPiuRecente() {
        let sorted = ClaudeProjectStatus.sortedByUrgency([
            project("/vecchio", .working, now.addingTimeInterval(-600)),
            project("/nuovo", .working, now),
        ])

        XCTAssertEqual(sorted.map(\.projectPath), ["/nuovo", "/vecchio"])
    }

    /// Il caso che ha motivato tutto: progetti indistinguibili per stato **e**
    /// per istante.
    ///
    /// Prima l'ordine era quello dei valori di un dizionario, cioè nessun ordine:
    /// un widget che ne mostra tre cambiava i tre mostrati da sé, senza che sul
    /// Mac fosse successo niente. Qui si prova che qualunque mescolata in
    /// ingresso dà lo stesso ordine in uscita.
    func testStabileConIstantiIdentici() {
        let paths = ["/z/uno", "/a/due", "/m/tre", "/b/quattro"]
        let atteso = ClaudeProjectStatus.sortedByUrgency(
            paths.map { project($0, .idle, now) }
        ).map(\.projectPath)

        for _ in 0..<20 {
            let mescolato = ClaudeProjectStatus.sortedByUrgency(
                paths.shuffled().map { project($0, .idle, now) }
            ).map(\.projectPath)
            XCTAssertEqual(mescolato, atteso)
        }

        // E l'ordine su cui si assesta è quello dei percorsi, non un caso.
        XCTAssertEqual(atteso, ["/a/due", "/b/quattro", "/m/tre", "/z/uno"])
    }
}

/// «Vale la pena svegliare il telefono?» — che è una domanda diversa da «è
/// cambiato qualcosa?».
///
/// Confonderle era il difetto dietro «i dati si aggiornano un po' lentamente»:
/// ogni percentuale che saliva spendeva un risveglio, e i risvegli in sottofondo
/// iOS li concede con parsimonia.
final class WakeUrgencyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func island(
        five: Double,
        projects: [ClaudeIslandState.Project],
        pending: String? = nil,
        alert: String? = nil
    ) -> ClaudeIslandState {
        ClaudeIslandState(
            fiveHourPercent: five,
            fiveHourResetsAt: now,
            sevenDayPercent: 9,
            projects: projects,
            alertKind: alert,
            pending: pending,
            updatedAt: now
        )
    }

    private let working = ClaudeIslandState.Project(
        name: "hub", path: "/a/hub", state: .working, alerting: false
    )
    private let waiting = ClaudeIslandState.Project(
        name: "hub", path: "/a/hub", state: .waitingInput, alerting: false
    )

    /// Il caso per cui esiste: sale l'utilizzo e non è cambiato niente altro.
    /// «È cambiato qualcosa» dice sì, «vale la pena» deve dire no.
    func testSoloLaPercentualeNonMeritaUnRisveglio() {
        let prima = island(five: 14, projects: [working])
        let dopo = island(five: 15, projects: [working])

        XCTAssertTrue(prima.describesSameSituation(as: dopo))
        XCTAssertFalse(
            prima.describesSameContent(as: dopo),
            "il widget va comunque ridisegnato quando lo si guarda: cambia il numero"
        )
    }

    /// Anche la data di azzeramento si muove da sé, minuto per minuto.
    func testAncheLAzzeramentoScorreDaSolo() {
        var dopo = island(five: 14, projects: [working])
        dopo.fiveHourResetsAt = now.addingTimeInterval(-60)
        XCTAssertTrue(island(five: 14, projects: [working]).describesSameSituation(as: dopo))
    }

    /// Un progetto che si mette ad aspettare: è la cosa per cui ci si alza dalla
    /// sedia, e deve passare davanti.
    func testUnoStatoCheCambiaMeritaUnRisveglio() {
        XCTAssertFalse(
            island(five: 14, projects: [working])
                .describesSameSituation(as: island(five: 14, projects: [waiting]))
        )
    }

    func testUnProgettoInPiuMeritaUnRisveglio() {
        XCTAssertFalse(
            island(five: 14, projects: [working])
                .describesSameSituation(as: island(five: 14, projects: [working, waiting]))
        )
    }

    func testUnaRichiestaInAttesaMeritaUnRisveglio() {
        XCTAssertFalse(
            island(five: 14, projects: [waiting])
                .describesSameSituation(as: island(five: 14, projects: [waiting],
                                                   pending: "posso scrivere?"))
        )
    }

    func testUnAvvisoMeritaUnRisveglio() {
        XCTAssertFalse(
            island(five: 14, projects: [working])
                .describesSameSituation(as: island(five: 14, projects: [working],
                                                   alert: "done"))
        )
    }
}
