import XCTest
@testable import MascotCore

/// Dove finiscono barra e fumetto, e soprattutto dove **resta** il personaggio.
///
/// La regola nasce da un difetto segnalato il 2026-09-21: con il pupazzetto
/// vicino al bordo destro, aprire la barra lo faceva scivolare a sinistra per
/// farle posto. La mascotte sta dove l'hai messa; è la barra a scansarsi.
final class MascotChromeLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let character = CGSize(width: 96, height: 96)
    private let gap: CGFloat = 14
    private let accessory: CGFloat = 268
    private let barHeight: CGFloat = 50
    private let bubbleHeight: CGFloat = 62

    private func chrome(bubble: Bool = false, bar: Bool = false) -> MascotChrome {
        MascotChrome(
            bubbleHeight: bubble ? bubbleHeight : 0,
            barHeight: bar ? barHeight : 0,
            accessoryWidth: accessory,
            gap: gap
        )
    }

    private func layout(
        at topLeft: CGPoint, bubble: Bool = false, bar: Bool = false
    ) -> MascotChromeFrame {
        MascotChromeLayout.frame(
            characterTopLeft: topLeft,
            characterSize: character,
            chrome: chrome(bubble: bubble, bar: bar),
            in: screen
        )
    }

    // MARK: - Senza niente attorno

    func testDaSoloLaFinestraEIlPersonaggio() {
        let frame = layout(at: CGPoint(x: 500, y: 400))
        XCTAssertEqual(frame.panel, CGRect(x: 500, y: 304, width: 96, height: 96))
        XCTAssertEqual(frame.characterInset, 0)
        XCTAssertTrue(frame.above.isEmpty)
        XCTAssertTrue(frame.below.isEmpty)
    }

    // MARK: - Di lato

    func testConSpazioLaBarraSiCentraSulPersonaggio() {
        let frame = layout(at: CGPoint(x: 600, y: 400), bar: true)
        // Il centro della barra cade sul centro del personaggio.
        let characterMid = frame.characterInset + character.width / 2
        XCTAssertEqual(frame.accessoryInset + accessory / 2, characterMid, accuracy: 0.5)
        XCTAssertEqual(frame.characterTopLeft, CGPoint(x: 600, y: 400))
    }

    /// Il difetto segnalato: contro il bordo destro, il personaggio non si deve
    /// muovere di un pixel.
    func testControIlBordoDestroSiScansaLaBarraNonIlPersonaggio() {
        let topLeft = CGPoint(x: screen.maxX - 96 - 10, y: 400)
        let frame = layout(at: topLeft, bar: true)

        XCTAssertEqual(frame.characterTopLeft, topLeft, "il personaggio si è spostato")
        // La barra è tutta dentro lo schermo…
        let barX = frame.panel.minX + frame.accessoryInset
        XCTAssertGreaterThanOrEqual(barX, screen.minX)
        XCTAssertLessThanOrEqual(barX + accessory, screen.maxX)
        // …con il suo margine dal bordo.
        XCTAssertEqual(barX + accessory, screen.maxX - MascotChromeLayout.screenMargin)
        // La finestra è l'unione dei due, quindi arriva fin dove arriva la barra.
        XCTAssertEqual(frame.panel.maxX, screen.maxX - MascotChromeLayout.screenMargin)
    }

    func testControIlBordoSinistroValeLoStesso() {
        let topLeft = CGPoint(x: screen.minX + 8, y: 400)
        let frame = layout(at: topLeft, bar: true)
        XCTAssertEqual(frame.characterTopLeft, topLeft)
        // La barra si ferma al margine, e la finestra comincia da lì.
        XCTAssertEqual(
            frame.panel.minX + frame.accessoryInset,
            screen.minX + MascotChromeLayout.screenMargin
        )
        XCTAssertEqual(frame.panel.minX, screen.minX + MascotChromeLayout.screenMargin)
    }

    // MARK: - Sopra e sotto

    func testConSpazioLaBarraStaSotto() {
        let frame = layout(at: CGPoint(x: 600, y: 500), bar: true)
        XCTAssertEqual(frame.below, [.bar])
        XCTAssertTrue(frame.above.isEmpty)
        XCTAssertEqual(frame.panel.height, 96 + gap + barHeight)
    }

    /// Il caso normale, non un caso limite: la mascotte vive in fondo allo
    /// schermo, ed è lì che la barra non ci sta sotto.
    func testInFondoAlloSchermoLaBarraPassaSopra() {
        let topLeft = CGPoint(x: 600, y: screen.minY + 96 + 10)
        let frame = layout(at: topLeft, bar: true)
        XCTAssertEqual(frame.above, [.bar])
        XCTAssertTrue(frame.below.isEmpty)
        XCTAssertEqual(frame.characterTopLeft, topLeft, "il personaggio si è spostato")
    }

    func testIlFumettoStaSopra() {
        let frame = layout(at: CGPoint(x: 600, y: 500), bubble: true)
        XCTAssertEqual(frame.above, [.bubble])
        XCTAssertEqual(frame.panel.height, 96 + gap + bubbleHeight)
    }

    func testControIlSoffittoIlFumettoPassaSotto() {
        let frame = layout(at: CGPoint(x: 600, y: screen.maxY - 4), bubble: true)
        XCTAssertEqual(frame.below, [.bubble])
        XCTAssertTrue(frame.above.isEmpty)
    }

    func testFumettoSopraEBarraSotto() {
        let frame = layout(at: CGPoint(x: 600, y: 500), bubble: true, bar: true)
        XCTAssertEqual(frame.above, [.bubble])
        XCTAssertEqual(frame.below, [.bar])
        XCTAssertEqual(frame.panel.height, bubbleHeight + gap + 96 + gap + barHeight)
        // Il personaggio sta in mezzo, sotto al fumetto.
        XCTAssertEqual(frame.panel.maxY - frame.characterTopLeft.y, bubbleHeight + gap)
    }

    /// In fondo allo schermo finiscono tutti e due sopra, e la barra resta
    /// quella più vicina al personaggio: è quella con cui si interagisce.
    func testInFondoVannoEntrambiSopraConLaBarraPiuVicina() {
        let frame = layout(
            at: CGPoint(x: 600, y: screen.minY + 96 + 10), bubble: true, bar: true
        )
        XCTAssertEqual(frame.above, [.bubble, .bar])
        XCTAssertTrue(frame.below.isEmpty)
        XCTAssertEqual(frame.panel.height, bubbleHeight + gap + barHeight + gap + 96)
    }

    // MARK: - Ultima risorsa

    /// Se non c'è proprio modo di starci dentro, allora sì che si sposta tutto:
    /// meglio un personaggio spostato di uno fuori dallo schermo.
    func testSchermoTroppoBassoSpostaTutto() {
        let stretto = CGRect(x: 0, y: 0, width: 400, height: 150)
        let frame = MascotChromeLayout.frame(
            characterTopLeft: CGPoint(x: 100, y: 140),
            characterSize: character,
            chrome: chrome(bar: true),
            in: stretto
        )
        // Non ci sta: si appoggia in basso e sfora in alto, invece di sparire
        // sotto il bordo dove non si potrebbe più prendere.
        XCTAssertEqual(frame.panel.minY, stretto.minY)
    }

    /// Uno schermo più stretto della barra: non si può fare niente di giusto,
    /// ma non si deve restituire una finestra fuori dal mondo.
    func testSchermoPiuStrettoDellaBarra() {
        let stretto = CGRect(x: 0, y: 0, width: 200, height: 900)
        let frame = MascotChromeLayout.frame(
            characterTopLeft: CGPoint(x: 50, y: 500),
            characterSize: character,
            chrome: chrome(bar: true),
            in: stretto
        )
        XCTAssertEqual(frame.panel.minX, stretto.minX)
        XCTAssertFalse(frame.panel.width.isNaN)
    }
}
