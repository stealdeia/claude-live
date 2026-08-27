import XCTest
@testable import ClaudeLiveKit

/// Quanto manca all'azzeramento, in una forma che si legge senza dividere.
///
/// Chiesto così (Stefano, 2026-08-27): «per quello dei 7 giorni non darmi le ore,
/// dammi i giorni e le ore residue» — perché sull'isola compariva «89:18:03».
final class ResetDelayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func delay(_ seconds: TimeInterval) -> String {
        Format.resetDelay(until: now.addingTimeInterval(seconds), now: now)
    }

    func testMinutes() {
        XCTAssertEqual(delay(35 * 60), "35 min")
        XCTAssertEqual(delay(59 * 60), "59 min")
    }

    /// Meno di un minuto è ancora «1 min»: «0 min» si legge come «adesso», che è
    /// un fatto diverso.
    func testUnderAMinuteRoundsUp() {
        XCTAssertEqual(delay(20), "1 min")
    }

    func testHoursAndMinutes() {
        XCTAssertEqual(delay(3 * 3600 + 28 * 60), "3h 28m")
        XCTAssertEqual(delay(5 * 3600), "5h")
    }

    /// Il caso per cui esiste: 89 ore sono tre giorni e diciassette ore, e
    /// «89:18:03» costringeva a farne il conto.
    func testDaysAndHours() {
        XCTAssertEqual(delay(89 * 3600 + 18 * 60), "3g 17h")
        XCTAssertEqual(delay(7 * 24 * 3600), "7g")
    }

    func testPastIsNow() {
        XCTAssertEqual(delay(-10), "adesso")
        XCTAssertEqual(delay(0), "adesso")
    }
}
