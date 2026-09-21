import XCTest
@testable import MascotCore

/// La mascotte deve restare afferrabile.
///
/// Il caso che conta davvero è il monitor scollegato: la posizione salvata
/// indica un punto che non esiste più, e senza un riporto dentro lo schermo la
/// mascotte si accende fuori dal visibile — dove non si vede e quindi non si
/// può nemmeno trascinare indietro.
final class MascotPlacementTests: XCTestCase {
    /// Un finto schermo 1440×900 che non parte da zero, così un errore di segno
    /// nei conti non può passare inosservato.
    private let visible = CGRect(x: 100, y: 50, width: 1440, height: 900)
    private let size = CGSize(width: 96, height: 120)

    func testPuntoGiaDentroNonSiMuove() {
        let inside = CGPoint(x: 400, y: 600)
        XCTAssertEqual(MascotPlacement.clamped(topLeft: inside, size: size, in: visible), inside)
    }

    func testSporgenzaADestraRientra() {
        let clamped = MascotPlacement.clamped(
            topLeft: CGPoint(x: 1600, y: 600), size: size, in: visible
        )
        // Il bordo destro della mascotte tocca il bordo destro dello schermo.
        XCTAssertEqual(clamped.x + size.width, visible.maxX)
        XCTAssertEqual(clamped.y, 600)
    }

    func testSporgenzaASinistraRientra() {
        let clamped = MascotPlacement.clamped(
            topLeft: CGPoint(x: -500, y: 600), size: size, in: visible
        )
        XCTAssertEqual(clamped.x, visible.minX)
    }

    /// In basso il riferimento è l'angolo *alto* della mascotte, quindi il limite
    /// non è il bordo dello schermo ma il bordo più l'altezza: è esattamente il
    /// conto che è facile sbagliare.
    func testSporgenzaInBassoRientraPerIntero() {
        let clamped = MascotPlacement.clamped(
            topLeft: CGPoint(x: 400, y: -200), size: size, in: visible
        )
        XCTAssertEqual(clamped.y - size.height, visible.minY)
    }

    func testSporgenzaInAltoRientra() {
        let clamped = MascotPlacement.clamped(
            topLeft: CGPoint(x: 400, y: 5000), size: size, in: visible
        )
        XCTAssertEqual(clamped.y, visible.maxY)
    }

    /// Schermo più piccolo della mascotte: nessun intervallo valido. Non deve
    /// andare in crash né restituire un punto assurdo — si appoggia in alto a
    /// sinistra, l'unico angolo da cui resta afferrabile.
    func testSchermoPiuPiccoloDellaMascotte() {
        let tiny = CGRect(x: 0, y: 0, width: 40, height: 40)
        let clamped = MascotPlacement.clamped(
            topLeft: CGPoint(x: 999, y: -999), size: size, in: tiny
        )
        XCTAssertEqual(clamped, CGPoint(x: 0, y: 40))
    }

    func testPosizionePredefinitaInBassoADestra() {
        let start = MascotPlacement.defaultTopLeft(size: size, in: visible)
        XCTAssertEqual(start.x, visible.maxX - size.width - MascotPlacement.margin)
        XCTAssertEqual(start.y, visible.minY + size.height + MascotPlacement.margin)
        // E comunque dentro: il margine non deve poter spingere fuori.
        XCTAssertEqual(MascotPlacement.clamped(topLeft: start, size: size, in: visible), start)
    }

    /// Un monitor spostato nella disposizione non deve spostare la mascotte sul
    /// monitor: è il motivo per cui si salva il relativo e non il globale.
    func testRelativoEAssolutoSonoInversi() {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let topLeft = CGPoint(x: -300, y: 900)
        let relative = MascotPlacement.relative(topLeft: topLeft, screenFrame: screen)
        XCTAssertEqual(relative, CGPoint(x: 1620, y: 700))
        XCTAssertEqual(
            MascotPlacement.absolute(relativeTopLeft: relative, screenFrame: screen),
            topLeft
        )
    }

    /// Lo stesso posto su un monitor che nel frattempo è stato spostato a destra
    /// del portatile invece che a sinistra.
    func testStessoPostoSuMonitorSpostato() {
        let before = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let after = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let relative = MascotPlacement.relative(
            topLeft: CGPoint(x: -200, y: 300), screenFrame: before
        )
        XCTAssertEqual(
            MascotPlacement.absolute(relativeTopLeft: relative, screenFrame: after),
            CGPoint(x: 3232, y: 300)
        )
    }
}
