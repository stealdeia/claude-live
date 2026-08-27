import XCTest
@testable import ClaudeLiveKit

/// L'ora di un messaggio: quanto tempo fa, oppure quando, oppure quando e che
/// giorno.
///
/// Le tre forme e i loro confini sono chiesti così (Stefano, 2026-08-27): «i
/// messaggi della chat hanno il tempo (2 minuti fa), oltre un'ora viene segnato
/// l'orario in cui è stato mandato. Se è in un'altra data diversa da oggi,
/// segnare anche la data».
final class MessageTimeTests: XCTestCase {

    /// Un'ora fissa a metà giornata, così nessuna prova cade a cavallo della
    /// mezzanotte quando gira di notte.
    private let now: Date = {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 8; parts.day = 27
        parts.hour = 15; parts.minute = 0
        return Calendar.current.date(from: parts)!
    }()

    private func time(ago seconds: TimeInterval) -> String {
        Format.messageTime(now.addingTimeInterval(-seconds), now: now)
    }

    // MARK: - Quanto tempo fa

    func testJustNow() {
        XCTAssertEqual(time(ago: 0), "adesso")
        XCTAssertEqual(time(ago: 44), "adesso")
    }

    func testOneMinute() {
        XCTAssertEqual(time(ago: 60), "un minuto fa")
    }

    func testMinutes() {
        XCTAssertEqual(time(ago: 120), "2 minuti fa")
        XCTAssertEqual(time(ago: 59 * 60), "59 minuti fa")
    }

    /// Due orologi che non concordano — quello del Mac e quello del telefono —
    /// possono dare un messaggio di qualche secondo nel futuro. «Fra un minuto»
    /// sarebbe una spiegazione peggiore del silenzio.
    func testSlightlyInTheFutureReadsAsNow() {
        XCTAssertEqual(Format.messageTime(now.addingTimeInterval(20), now: now), "adesso")
    }

    // MARK: - Quando

    /// Oltre l'ora conta *quando*, non *quanto tempo fa*: «sette ore fa»
    /// costringe a un conto per sapere se era prima o dopo pranzo.
    func testOverAnHourShowsTheClock() {
        XCTAssertEqual(time(ago: 3600), "14:00")
        XCTAssertEqual(time(ago: 7 * 3600), "08:00")
    }

    // MARK: - Quando e che giorno

    func testYesterdayIsNamed() {
        // Non «26 ago»: «ieri» è ciò che si capisce senza pensarci.
        XCTAssertEqual(time(ago: 24 * 3600), "ieri 15:00")
    }

    /// Senza il giorno, «14:35» di tre giorni fa si legge come oggi.
    func testOlderShowsTheDate() {
        let rendered = time(ago: 3 * 24 * 3600)
        XCTAssertTrue(rendered.contains("24"), "manca il giorno: \(rendered)")
        XCTAssertTrue(rendered.contains("15:00"), "manca l'ora: \(rendered)")
    }

    /// Mezzanotte passata da poco è «ieri» anche se sono passate due ore: conta
    /// il giorno, non la distanza.
    func testEarlyMorningCallsLastNightYesterday() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 8; parts.day = 27
        parts.hour = 1; parts.minute = 0
        let pastMidnight = Calendar.current.date(from: parts)!
        let lateLastNight = pastMidnight.addingTimeInterval(-2 * 3600)
        XCTAssertEqual(Format.messageTime(lateLastNight, now: pastMidnight), "ieri 23:00")
    }
}
