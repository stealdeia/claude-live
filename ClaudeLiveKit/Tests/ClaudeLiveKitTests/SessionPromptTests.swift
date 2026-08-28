import XCTest
@testable import ClaudeLiveKit

/// Un'attesa di seguito non è una richiesta di permesso.
///
/// Perché esistono: le due cose viaggiano nello stesso file e nella stessa
/// cartella, e distinguerle è una riga sola — che è esattamente il genere di riga
/// che si dimentica. Dimenticata, sul telefono compariva «Claude chiede un
/// permesso» con la riga del comando vuota, e premere «Consenti» non faceva
/// proseguire niente: l'hook aspettava delle parole e riceveva un permesso.
final class SessionPromptTests: XCTestCase {

    private func session(promptRequestID: String? = nil) -> ClaudeSessionStatus {
        var json: [String: Any] = [
            "project_path": "/Users/tizio/Repository/sito",
            "state": "idle",
            "session_id": "s-1",
            "event": "Stop",
        ]
        if let promptRequestID { json["prompt_request_id"] = promptRequestID }
        return ClaudeSessionStatus(json: json)!
    }

    func testASessionWithoutAHoldAcceptsNothing() {
        XCTAssertFalse(session().acceptsPrompt)
        XCTAssertNil(session().promptRequestID)
    }

    func testTheHoldIsReadFromTheRecord() {
        let waiting = session(promptRequestID: "prompt-s-1")
        XCTAssertTrue(waiting.acceptsPrompt)
        XCTAssertEqual(waiting.promptRequestID, "prompt-s-1")
    }

    /// Aperta dalla cartella delle richieste, che è la fonte affidabile.
    func testTheHoldCanBeOpened() {
        let opened = session().awaitingPrompt("prompt-s-1")
        XCTAssertTrue(opened.acceptsPrompt)
        XCTAssertEqual(opened.state, .idle, "aprire l'attesa non cambia lo stato")
    }

    /// E chiusa: se l'hook è stato ucciso senza correggere il file di stato,
    /// offrire una casella raccoglierebbe parole che non arrivano da nessuna
    /// parte.
    func testTheHoldIsClosedWhenNothingIsPendingAnyMore() {
        let stale = session(promptRequestID: "prompt-s-1")
        XCTAssertFalse(stale.awaitingPrompt(nil).acceptsPrompt)
    }

    /// Il difetto vero, nel modello: un permesso resta un permesso, e non deve
    /// portarsi dietro un'attesa di seguito che nessuno ha aperto.
    func testAPermissionIsNotAPromptHold() {
        let asked = session().answering(
            requestID: "toolu_1", toolName: "Bash", toolSummary: "git push"
        )
        XCTAssertTrue(asked.isDecidable)
        XCTAssertFalse(asked.acceptsPrompt, "un permesso non è un'attesa di seguito")
        XCTAssertEqual(asked.requestKind, "permission")
    }

    /// E il contrario: un'attesa di seguito non deve offrire «Consenti» e «Nega».
    func testAPromptHoldIsNotDecidable() {
        let waiting = session().awaitingPrompt("prompt-s-1")
        XCTAssertFalse(
            waiting.isDecidable,
            "con «decidable» il telefono mostrerebbe Consenti/Nega con il comando vuoto"
        )
    }
}
