import XCTest
@testable import ClaudeLiveKit

/// Che cosa di una trascrizione è conversazione e che cosa non lo è.
///
/// Le forme provate qui sono misurate su una trascrizione vera (2026-08-27, una
/// sessione di questo progetto): 676 chiamate agli strumenti, 675 risultati, 537
/// ragionamenti interni, 572 messaggi di testo. Il formato non è documentato,
/// quindi è l'unica parte del lettore che vale la pena sorvegliare.
final class ClaudeMessageTests: XCTestCase {

    // MARK: - Cosa si tiene

    func testAssistantTextIsKept() {
        let record: [String: Any] = [
            "type": "assistant",
            "message": ["role": "assistant", "content": [
                ["type": "text", "text": "Ho corretto il difetto."],
            ]],
        ]
        let message = ClaudeMessage.from(record: record)
        XCTAssertEqual(message?.author, .assistant)
        XCTAssertEqual(message?.text, "Ho corretto il difetto.")
    }

    func testUserTextIsKept() {
        let record: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": "Vai."]]],
        ]
        XCTAssertEqual(ClaudeMessage.from(record: record)?.author, .user)
        XCTAssertEqual(ClaudeMessage.from(record: record)?.text, "Vai.")
    }

    /// Tredici record su una sessione portavano il contenuto come stringa nuda
    /// invece che come elenco di blocchi.
    func testContentAsPlainStringIsKept() {
        let record: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": "Ciao"],
        ]
        XCTAssertEqual(ClaudeMessage.from(record: record)?.text, "Ciao")
    }

    func testSeveralTextBlocksAreJoined() {
        let record: [String: Any] = [
            "type": "assistant",
            "message": ["content": [
                ["type": "text", "text": "Primo."],
                ["type": "text", "text": "Secondo."],
            ]],
        ]
        XCTAssertEqual(ClaudeMessage.from(record: record)?.text, "Primo.\n\nSecondo.")
    }

    // MARK: - Cosa si butta

    /// Il ragionamento interno non è ciò che Claude ha *detto*: mostrarlo come un
    /// messaggio darebbe della conversazione un resoconto che non contiene.
    func testThinkingIsDropped() {
        let record: [String: Any] = [
            "type": "assistant",
            "message": ["content": [
                ["type": "thinking", "thinking": "Forse è la variabile sovrascritta."],
                ["type": "text", "text": "Ho trovato."],
            ]],
        ]
        XCTAssertEqual(ClaudeMessage.from(record: record)?.text, "Ho trovato.")
    }

    func testToolUseOnlyIsNotAMessage() {
        let record: [String: Any] = [
            "type": "assistant",
            "message": ["content": [
                ["type": "tool_use", "name": "Bash", "input": ["command": "ls"]],
            ]],
        ]
        XCTAssertNil(ClaudeMessage.from(record: record))
    }

    /// Sono la maggioranza dei record `user`: 675 contro 75 di testo vero.
    func testToolResultIsNotAMessage() {
        let record: [String: Any] = [
            "type": "user",
            "message": ["content": [
                ["type": "tool_result", "content": "totale 48", "tool_use_id": "toolu_01"],
            ]],
        ]
        XCTAssertNil(ClaudeMessage.from(record: record))
    }

    func testImageOnlyIsNotAMessage() {
        let record: [String: Any] = [
            "type": "user",
            "message": ["content": [["type": "image", "source": ["data": "..."]]]],
        ]
        XCTAssertNil(ClaudeMessage.from(record: record))
    }

    func testOtherRecordTypesAreIgnored() {
        for kind in ["ai-title", "system", "attachment", "queue-operation", "last-prompt"] {
            let record: [String: Any] = [
                "type": kind,
                "message": ["content": [["type": "text", "text": "qualcosa"]]],
            ]
            XCTAssertNil(ClaudeMessage.from(record: record), "\(kind) non è un messaggio")
        }
    }

    // MARK: - Il rumore infilato nei messaggi dell'utente

    func testSystemReminderIsStripped() {
        let record: [String: Any] = [
            "type": "user",
            "message": ["content": [["type": "text", "text":
                "Sistemami il bug<system-reminder>Ricorda le istruzioni.</system-reminder>"]]],
        ]
        XCTAssertEqual(ClaudeMessage.from(record: record)?.text, "Sistemami il bug")
    }

    func testSeveralNoiseTagsAreAllStripped() {
        let record: [String: Any] = [
            "type": "user",
            "message": ["content": [["type": "text", "text":
                "<system-reminder>uno</system-reminder>Vero"
                    + "<system-reminder>due</system-reminder>"
                    + "<ide_selection>riga 12</ide_selection>"]]],
        ]
        XCTAssertEqual(ClaudeMessage.from(record: record)?.text, "Vero")
    }

    /// Un messaggio che era *solo* un promemoria non è un messaggio: mostrarlo
    /// vuoto sarebbe una bolla che non vuol dire niente.
    func testMessageThatIsOnlyNoiseDisappears() {
        let record: [String: Any] = [
            "type": "user",
            "message": ["content": [["type": "text", "text":
                "<system-reminder>solo questo</system-reminder>"]]],
        ]
        XCTAssertNil(ClaudeMessage.from(record: record))
    }

    // MARK: - L'avviso che sembrava un messaggio

    /// Il difetto del 2026-08-27: nella chat sul telefono comparivano fumetti
    /// attribuiti a Stefano che contenevano l'avviso di fine di un lavoro in
    /// sottofondo. «Viene fuori questa ma io non ho mai scritto nulla.»
    func testTaskNotificationIsNotAMessage() {
        let record: [String: Any] = [
            "type": "user",
            "message": ["content": [["type": "text", "text":
                "<task-notification>\n<task-id>br73</task-id>\n<status>completed</status>\n</task-notification>"]]],
        ]
        XCTAssertNil(ClaudeMessage.from(record: record))
    }

    /// La regola generale, che non ha bisogno di conoscere il nome: un elenco di
    /// nomi noti è sempre in ritardo di un difetto.
    func testAnyMessageThatIsOneWholeElementIsDropped() {
        for tag in ["qualcosa-di-nuovo", "avviso_interno", "wrapper42"] {
            let record: [String: Any] = [
                "type": "user",
                "message": ["content": [["type": "text", "text": "<\(tag)>contenuto</\(tag)>"]]],
            ]
            XCTAssertNil(ClaudeMessage.from(record: record), "<\(tag)> non è una frase detta")
        }
    }

    /// Il punto delicato della regola: le etichette compaiono anche *dentro* i
    /// messaggi veri, e togliere ogni cosa fra parentesi angolari mangerebbe
    /// pezzi di conversazione.
    func testTagsInsideRealProseSurvive() {
        let record: [String: Any] = [
            "type": "user",
            "message": ["content": [["type": "text", "text":
                "Nel file c'è <project> e anche <id>, non toccarli."]]],
        ]
        XCTAssertEqual(
            ClaudeMessage.from(record: record)?.text,
            "Nel file c'è <project> e anche <id>, non toccarli."
        )
    }

    func testMessageStartingWithATagButContinuingIsKept() {
        let record: [String: Any] = [
            "type": "user",
            "message": ["content": [["type": "text", "text": "<b>ciao</b> e poi altro"]]],
        ]
        XCTAssertNotNil(ClaudeMessage.from(record: record))
    }

    // MARK: - Lunghezza

    func testLongMessageIsShortened() {
        let long = String(repeating: "a", count: 2000)
        let record: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "text", "text": long]]],
        ]
        let text = ClaudeMessage.from(record: record, maxCharacters: 100)?.text
        XCTAssertEqual(text?.count, 101, "cento caratteri più i puntini")
        XCTAssertTrue(text?.hasSuffix("…") == true)
    }

    /// Zero vuol dire «nessun taglio»: dal 2026-08-27 i messaggi arrivano
    /// interi, perché la misura ha mostrato che il taglio non risparmiava niente
    /// e rovinava proprio i messaggi che valeva la pena leggere.
    func testZeroLimitMeansNoTruncation() {
        let long = String(repeating: "a", count: 5000)
        let record: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "text", "text": long]]],
        ]
        XCTAssertEqual(ClaudeMessage.from(record: record, maxCharacters: 0)?.text.count, 5000)
    }

    func testShortMessageIsUntouched() {
        let record: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "text", "text": "Breve."]]],
        ]
        XCTAssertEqual(ClaudeMessage.from(record: record, maxCharacters: 100)?.text, "Breve.")
    }

    // MARK: - L'ora

    func testTimestampWithMillisecondsIsRead() {
        let record: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "text", "text": "x"]]],
            "timestamp": "2026-08-20T07:11:51.845Z",
        ]
        // La forma che le trascrizioni usano davvero, e che il formato
        // predefinito di ISO8601DateFormatter rifiuta.
        XCTAssertNotNil(ClaudeMessage.from(record: record)?.at)
    }

    func testTimestampWithoutMillisecondsIsRead() {
        let record: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "text", "text": "x"]]],
            "timestamp": "2026-08-20T07:11:51Z",
        ]
        XCTAssertNotNil(ClaudeMessage.from(record: record)?.at)
    }

    /// Le prime righe di una sessione a volte non hanno l'ora: mancarla è meglio
    /// che inventarla.
    func testMissingTimestampIsNil() {
        let record: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "text", "text": "x"]]],
        ]
        XCTAssertNil(ClaudeMessage.from(record: record)?.at)
    }
}
