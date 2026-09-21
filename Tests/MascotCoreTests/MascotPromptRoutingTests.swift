import XCTest
@testable import MascotCore

/// A chi parla la barra.
///
/// È la regola che decide se quello che scrivi parte subito, resta in coda per
/// quando Claude avrà finito, o non parte affatto — e sbagliarla vuol dire
/// consegnare un messaggio nel punto sbagliato di una conversazione, che è il
/// danno peggiore che questa funzione possa fare.
final class MascotPromptRoutingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(
        _ id: String,
        project: String = "sito",
        working: Bool = false,
        followUp: Bool = false,
        question: String? = nil,
        permission: Bool = false,
        age: TimeInterval = 0
    ) -> MascotPromptCandidate {
        MascotPromptCandidate(
            sessionID: id,
            projectName: project,
            isWorking: working,
            acceptsFollowUp: followUp,
            pendingQuestion: question,
            awaitingPermission: permission,
            updatedAt: now.addingTimeInterval(-age)
        )
    }

    func testSenzaSessioniNonSiParlaConNessuno() {
        XCTAssertEqual(MascotPromptRouting.target(among: []), .none)
    }

    func testUnaSessioneFermaNonRiceveNiente() {
        // Claude non sta lavorando e non chiede niente: non c'è nessun turno
        // che finirà, quindi un messaggio in coda resterebbe lì per sempre.
        XCTAssertEqual(MascotPromptRouting.target(among: [candidate("a")]), .none)
    }

    func testMentreLavoraSiScriveInCoda() {
        XCTAssertEqual(
            MascotPromptRouting.target(among: [candidate("a", working: true)]),
            .queue(sessionID: "a", project: "sito")
        )
    }

    func testSeIlTurnoEtrattenutoIlTestoParteSubito() {
        XCTAssertEqual(
            MascotPromptRouting.target(among: [candidate("a", followUp: true)]),
            .followUp(sessionID: "a", project: "sito")
        )
    }

    func testUnaDomandaInSospesoVinceSuTutto() {
        let target = MascotPromptRouting.target(among: [
            candidate("lavora", working: true),
            candidate("chiede", question: "Quale vuoi?", age: 30),
        ])
        XCTAssertEqual(target, .question(sessionID: "chiede", project: "sito", question: "Quale vuoi?"))
    }

    /// Anche quando la sessione che chiede è la più vecchia: qualcuno è fermo ad
    /// aspettare una risposta, e mettere in coda un messaggio per un'altra chat
    /// lo lascerebbe lì.
    func testLaDomandaVinceAncheSeEPiuVecchia() {
        let target = MascotPromptRouting.target(among: [
            candidate("chiede", question: "Procedo?", age: 600),
            candidate("lavora", working: true),
            candidate("trattenuta", followUp: true, age: 5),
        ])
        XCTAssertEqual(target, .question(sessionID: "chiede", project: "sito", question: "Procedo?"))
    }

    func testIlSeguitoTrattenutoVinceSullaCoda() {
        let target = MascotPromptRouting.target(among: [
            candidate("lavora", working: true),
            candidate("trattenuta", followUp: true, age: 60),
        ])
        XCTAssertEqual(target, .followUp(sessionID: "trattenuta", project: "sito"))
    }

    /// Un permesso è l'unico caso in cui c'è qualcuno in attesa e non c'è niente
    /// da scrivere: si dice, invece di far scrivere a vuoto.
    func testUnPermessoNonSiRispondeScrivendo() {
        let target = MascotPromptRouting.target(among: [candidate("a", permission: true)])
        XCTAssertEqual(target, .permission(project: "sito"))
        XCTAssertFalse(target.acceptsText)
    }

    func testFraDueCheLavoranoVinceLaPiuRecente() {
        let target = MascotPromptRouting.target(among: [
            candidate("vecchia", project: "vecchio", working: true, age: 300),
            candidate("nuova", project: "nuovo", working: true, age: 2),
        ])
        XCTAssertEqual(target, .queue(sessionID: "nuova", project: "nuovo"))
    }

    func testDoveSiPuoScrivere() {
        XCTAssertTrue(MascotPromptTarget.queue(sessionID: "a", project: "p").acceptsText)
        XCTAssertTrue(MascotPromptTarget.followUp(sessionID: "a", project: "p").acceptsText)
        XCTAssertTrue(MascotPromptTarget.question(sessionID: "a", project: "p", question: "q").acceptsText)
        XCTAssertFalse(MascotPromptTarget.permission(project: "p").acceptsText)
        XCTAssertFalse(MascotPromptTarget.none.acceptsText)
        XCTAssertNil(MascotPromptTarget.none.project)
        XCTAssertEqual(MascotPromptTarget.queue(sessionID: "a", project: "p").project, "p")
    }

    // MARK: - Il nome del file

    /// L'app scrive il file, l'hook lo cerca: due programmi diversi che devono
    /// indicare lo stesso nome senza potersi parlare. Le regole sono copiate a
    /// mano da `claude-hub-status.py`, quindi questa prova è l'unico posto in
    /// cui una divergenza si vede.
    func testIlNomeDelFileSegueLeStesseRegoleDellHook() {
        XCTAssertEqual(MascotPromptRouting.queueFileName(forSession: "abc-123_x"), "abc-123_x.json")
        // Tutto il resto cade: punti, barre, spazi.
        XCTAssertEqual(
            MascotPromptRouting.queueFileName(forSession: "a.b/c d:e"),
            "abcde.json"
        )
        // Non più di quaranta caratteri, come nell'hook.
        let lungo = String(repeating: "z", count: 80)
        XCTAssertEqual(MascotPromptRouting.queueFileName(forSession: lungo).count, 45)
    }

    /// Un identificativo vero di Claude Code: deve passare intatto.
    func testUnIdentificativoVeroRestaIntatto() {
        let uuid = "70b97e26-119e-4aa9-83cd-bd81dcb6dc66"
        XCTAssertEqual(MascotPromptRouting.queueFileName(forSession: uuid), uuid + ".json")
    }
}
