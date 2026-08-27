import XCTest
@testable import ClaudeLiveKit

/// Il grassetto deve essere grassetto, e gli asterischi non si devono vedere.
///
/// Il difetto da cui nasce: nella chat sul telefono i messaggi di Claude
/// mostravano `**davvero**` invece di **davvero** (Stefano, 2026-08-27).
final class MessageMarkdownTests: XCTestCase {

    /// Il testo come lo si legge, senza le marcature.
    private func plain(_ text: String) -> String {
        String(MessageMarkdown.attributed(text).characters)
    }

    private func hasBold(_ text: String) -> Bool {
        MessageMarkdown.attributed(text).runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
    }

    // MARK: - Il grassetto

    func testBoldBecomesBoldAndLosesItsAsterisks() {
        let rendered = plain("Ho corretto **il difetto** stamattina.")
        XCTAssertEqual(rendered, "Ho corretto il difetto stamattina.")
        XCTAssertFalse(rendered.contains("*"), "gli asterischi non si devono vedere")
        XCTAssertTrue(hasBold("Ho corretto **il difetto** stamattina."))
    }

    func testItalicLosesItsAsterisks() {
        XCTAssertFalse(plain("Non è *questo* il punto.").contains("*"))
    }

    func testInlineCodeLosesItsBackticks() {
        XCTAssertFalse(plain("Guarda `await_decision` qui.").contains("`"))
    }

    // MARK: - Gli a capo

    /// Il lettore Markdown completo unirebbe i paragrafi in una riga sola, e un
    /// messaggio di Claude senza a capo è un muro.
    func testLineBreaksSurvive() {
        XCTAssertTrue(plain("Prima riga\nSeconda riga").contains("\n"))
    }

    // MARK: - Le costruzioni a blocchi

    func testHeadingBecomesABoldLine() {
        XCTAssertEqual(MessageMarkdown.prepared("## Come funziona"), "**Come funziona**")
        XCTAssertFalse(plain("## Come funziona").contains("#"))
        XCTAssertTrue(hasBold("## Come funziona"))
    }

    func testAlreadyBoldHeadingIsNotDoubled() {
        // Raddoppiare farebbe ricomparire gli asterischi, che è il difetto.
        XCTAssertEqual(MessageMarkdown.prepared("### **Attenzione**"), "**Attenzione**")
        XCTAssertFalse(plain("### **Attenzione**").contains("*"))
    }

    func testHashWithoutTextIsNotAHeading() {
        XCTAssertEqual(MessageMarkdown.prepared("###"), "###")
    }

    func testBulletsBecomeDots() {
        XCTAssertEqual(MessageMarkdown.prepared("- primo\n- secondo"), "• primo\n• secondo")
    }

    func testNestedBulletKeepsItsIndent() {
        XCTAssertEqual(MessageMarkdown.prepared("- primo\n    - dentro"), "• primo\n    • dentro")
    }

    /// `*corsivo*` comincia con un asterisco e non è un elenco: trattarlo come
    /// tale ne mangerebbe il primo carattere.
    func testItalicIsNotMistakenForABullet() {
        XCTAssertEqual(MessageMarkdown.prepared("*davvero* importante"), "*davvero* importante")
        XCTAssertEqual(plain("*davvero* importante"), "davvero importante")
    }

    func testCodeFencesDisappearAndTheCodeStays() {
        let source = "Prova questo:\n```swift\nlet x = 1\n```\nFatto."
        XCTAssertEqual(MessageMarkdown.prepared(source), "Prova questo:\nlet x = 1\nFatto.")
    }

    func testHorizontalRuleBecomesABlankLine() {
        XCTAssertEqual(MessageMarkdown.prepared("sopra\n---\nsotto"), "sopra\n\nsotto")
    }

    /// Una riga di trattini è un separatore, ma `- voce` è un elenco: il
    /// separatore ha bisogno di almeno tre segni e nessun testo.
    func testShortDashLineIsStillABullet() {
        XCTAssertEqual(MessageMarkdown.prepared("- x"), "• x")
    }

    // MARK: - Robustezza

    func testMalformedMarkdownStillShowsTheMessage() {
        // Meglio i simboli a vista che una bolla vuota.
        XCTAssertFalse(plain("**non chiuso e [link( rotto").isEmpty)
    }

    func testEmptyTextStaysEmpty() {
        XCTAssertEqual(plain(""), "")
    }
}
