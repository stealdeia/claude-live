import XCTest
@testable import MascotCore

/// Le regole del personaggio, provate senza aprire una finestra.
///
/// La macchina a stati è la parte che decide *tutto* quello che la mascotte fa,
/// e quasi nessuno dei suoi errori si vede subito: «non si addormenta mai»,
/// «dopo un avviso resta col salto a metà», «trascinandola mentre Claude lavora
/// torna ferma invece che al lavoro» sono cose che ci si accorge dopo un'ora di
/// uso, e a quel punto nessuno sa più da dove venivano.
final class MascotStateMachineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Cadenza fissa invece che casuale: una prova che dipende dal caso non è
    /// una prova. Il minimo dell'intervallo, così i conti si leggono.
    private func machine(
        sleepAfter: TimeInterval = 300,
        fidget: ClosedRange<TimeInterval> = 10...20
    ) -> MascotStateMachine {
        var m = MascotStateMachine(
            now: start,
            timing: .init(sleepAfter: sleepAfter, fidgetEvery: fidget, snoreEvery: 30...30)
        )
        m.randomInterval = { $0.lowerBound }
        return m
    }

    /// Accesa e messa sullo schermo: è il punto di partenza di ogni prova.
    /// `fidget` lunghissimo dove la prova non parla delle cosine: altrimenti un
    /// appuntamento scaduto durante un salto temporale si intrometterebbe nella
    /// risposta che si sta guardando.
    private func awake(fidget: ClosedRange<TimeInterval> = 10...20) -> MascotStateMachine {
        var m = machine(fidget: fidget)
        _ = m.handle(.appeared, now: start)
        return m
    }

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// Una notizia qualunque del tipo chiesto: qui si guardano le regole, non
    /// cosa c'è scritto nel fumetto.
    private func notice(_ kind: MascotNotice.Kind) -> MascotNotice {
        MascotNotice(kind: kind, project: "sito", detail: nil)
    }

    // MARK: - Partenza

    func testComparendoSiPosaFerma() {
        var m = machine()
        XCTAssertEqual(m.handle(.appeared, now: start), .hold(.idle))
        XCTAssertEqual(m.state, .idle)
    }

    func testNascostaNonDecidePiuNiente() {
        var m = awake()
        XCTAssertNil(m.handle(.disappeared, now: start))
        // Nessuna sveglia in programma: nascosta non deve far succedere niente.
        XCTAssertNil(m.nextWakeUp)
        XCTAssertNil(m.tick(now: at(10_000)))
        XCTAssertNil(m.handle(.event(.notice(notice(.finished))), now: at(10_000)))
    }

    // MARK: - Il riposo

    /// Il punto per cui esiste tutto questo: da ferma **non** gira niente. Si
    /// posa su un disegno e si dà appuntamento più tardi.
    func testDaFermaNonAnimaNiente() {
        var m = awake()
        XCTAssertEqual(m.nextWakeUp, at(10))
        // Prima del momento buono non succede niente.
        XCTAssertNil(m.tick(now: at(9)))
    }

    func testOgniTantoFaUnaCosina() {
        var m = awake()
        XCTAssertEqual(m.tick(now: at(10)), .play(.idle, once: true))
        // Finita la cosina torna ferma, e si dà il prossimo appuntamento.
        XCTAssertEqual(m.handle(.animationFinished(.idle), now: at(11)), .hold(.idle))
        XCTAssertEqual(m.nextWakeUp, at(21))
        XCTAssertNil(m.tick(now: at(20)))
        XCTAssertEqual(m.tick(now: at(21)), .play(.idle, once: true))
    }

    // MARK: - Il sonno

    func testDopoUnPoDiSilenzioSiAddormenta() {
        var m = awake(fidget: 10_000...10_000)
        XCTAssertNil(m.tick(now: at(299)))
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.tick(now: at(300)), .hold(.sleeping))
        XCTAssertEqual(m.state, .sleeping)
    }

    func testDormendoRussaPiuDiRado() {
        var m = awake(fidget: 10_000...10_000)
        _ = m.tick(now: at(300))
        XCTAssertEqual(m.nextWakeUp, at(330))
        XCTAssertEqual(m.tick(now: at(330)), .play(.sleeping, once: true))
    }

    func testUnaNotiziaLaSveglia() {
        var m = awake(fidget: 10_000...10_000)
        _ = m.tick(now: at(300))
        XCTAssertEqual(m.state, .sleeping)
        XCTAssertEqual(m.handle(.event(.notice(notice(.finished))), now: at(400)), .play(.notify, once: true))
        // E finito l'annuncio resta sveglia: il conto del sonno riparte da capo.
        XCTAssertEqual(m.handle(.animationFinished(.notify), now: at(401)), .hold(.idle))
        XCTAssertEqual(m.state, .idle)
    }

    /// Un segno di vita qualsiasi rimanda il sonno senza cambiare quello che sta
    /// facendo.
    func testUnCennoRimandaIlSonno() {
        var m = awake(fidget: 10_000...10_000)
        XCTAssertNil(m.handle(.event(.poked), now: at(250)))
        XCTAssertNil(m.tick(now: at(400)))
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.tick(now: at(550)), .hold(.sleeping))
    }

    /// Mentre c'è lavoro in corso non si addormenta: sarebbe la cosa più sbagliata
    /// da mostrare proprio mentre qualcosa sta succedendo.
    func testNonSiAddormentaMentreLavora() {
        var m = awake()
        XCTAssertEqual(m.handle(.event(.working(true)), now: start), .play(.working, once: false))
        XCTAssertNil(m.tick(now: at(10_000)))
        XCTAssertEqual(m.state, .working)
        XCTAssertNil(m.nextWakeUp)
    }

    /// Quando scadono insieme, addormentarsi viene prima dello sbadiglio:
    /// altrimenti il sonno slitterebbe di una cosina ogni volta.
    func testAddormentarsiVinceSullaCosina() {
        var m = awake(fidget: 400...400)
        XCTAssertEqual(m.tick(now: at(500)), .hold(.sleeping))
    }

    // MARK: - Lavoro e notizie

    func testFinitoIlLavoroTornaFerma() {
        var m = awake()
        _ = m.handle(.event(.working(true)), now: start)
        XCTAssertEqual(m.handle(.event(.working(false)), now: at(30)), .hold(.idle))
    }

    func testDopoUnAvvisoTornaAlLavoroSeIlLavoroContinua() {
        var m = awake()
        _ = m.handle(.event(.working(true)), now: start)
        XCTAssertEqual(m.handle(.event(.notice(notice(.needsYou))), now: at(5)), .play(.notify, once: true))
        // Il lavoro è uno sfondo che dura: l'avviso è passato, quello no.
        XCTAssertEqual(m.handle(.animationFinished(.notify), now: at(6)), .play(.working, once: false))
    }

    func testDueNotizieDiFilaFannoRicominciareIlSalto() {
        var m = awake()
        XCTAssertEqual(m.handle(.event(.notice(notice(.finished))), now: start), .play(.notify, once: true))
        XCTAssertEqual(m.handle(.event(.notice(notice(.failed))), now: at(1)), .play(.notify, once: true))
    }

    // MARK: - Il trascinamento

    func testInManoVinceSuTutto() {
        var m = awake()
        _ = m.handle(.event(.working(true)), now: start)
        XCTAssertEqual(m.handle(.dragBegan, now: at(1)), .play(.dragging, once: false))
        // Anche una notizia aspetta: in mano è in mano.
        XCTAssertNil(m.handle(.event(.notice(notice(.finished))), now: at(2)))
        XCTAssertEqual(m.state, .dragging)
    }

    func testLasciandolaAtterraEPoiRiprende() {
        var m = awake()
        _ = m.handle(.event(.working(true)), now: start)
        _ = m.handle(.dragBegan, now: at(1))
        XCTAssertEqual(m.handle(.dragEnded, now: at(2)), .play(.dropped, once: true))
        XCTAssertEqual(m.handle(.animationFinished(.dropped), now: at(3)), .play(.working, once: false))
    }

    func testAtterrandoSenzaNientaDaFareTornaFerma() {
        var m = awake()
        _ = m.handle(.dragBegan, now: at(1))
        _ = m.handle(.dragEnded, now: at(2))
        XCTAssertEqual(m.handle(.animationFinished(.dropped), now: at(3)), .hold(.idle))
        // E il conto del sonno riparte da quando l'hai lasciata.
        XCTAssertEqual(m.nextWakeUp, at(13))
    }

    /// Prenderla in mano mentre sta annunciando qualcosa interrompe l'annuncio:
    /// senza questo l'animazione dell'avviso finirebbe *dopo*, con il pupazzetto
    /// già atterrato, e si vedrebbe un salto dal nulla.
    func testPrenderlaInManoInterrompeLAvviso() {
        var m = awake()
        _ = m.handle(.event(.notice(notice(.finished))), now: start)
        XCTAssertEqual(m.handle(.dragBegan, now: at(1)), .play(.dragging, once: false))
        XCTAssertEqual(m.handle(.dragEnded, now: at(2)), .play(.dropped, once: true))
        XCTAssertEqual(m.handle(.animationFinished(.dropped), now: at(3)), .hold(.idle))
    }

    // MARK: - Niente lavoro inutile

    /// Ripetere un fatto che non cambia niente non deve produrre nessuna azione:
    /// è quello che tiene fermo il disegno invece di farlo ripartire di continuo.
    func testUnFattoCheNonCambiaNienteNonProduceAzioni() {
        var m = awake()
        XCTAssertEqual(m.handle(.event(.working(true)), now: start), .play(.working, once: false))
        XCTAssertNil(m.handle(.event(.working(true)), now: at(1)))
        XCTAssertNil(m.handle(.event(.working(true)), now: at(2)))
    }
}
