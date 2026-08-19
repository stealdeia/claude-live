import XCTest
@testable import ClaudeLiveKit

final class RemoteProtocolTests: XCTestCase {

    // MARK: - Freschezza dei comandi

    func testFreshCommandIsAccepted() {
        let envelope = RemoteCommandEnvelope(
            command: .decide(requestID: "toolu_01", allow: true, remember: false)
        )
        XCTAssertTrue(envelope.isFresh())
    }

    func testStaleCommandIsRefused() {
        let now = Date()
        let envelope = RemoteCommandEnvelope(
            command: .decide(requestID: "toolu_01", allow: true, remember: false),
            issuedAt: now.addingTimeInterval(-RemoteCommandEnvelope.maximumAge - 1)
        )
        // The case this exists for: the phone was offline when the button was
        // pressed and delivers the approval much later, to a question that has
        // long since been decided some other way.
        XCTAssertFalse(envelope.isFresh(now: now))
    }

    func testCommandFromTheFutureIsRefused() {
        let now = Date()
        let envelope = RemoteCommandEnvelope(
            command: .decide(requestID: "toolu_01", allow: true, remember: false),
            issuedAt: now.addingTimeInterval(600)
        )
        // A phone whose clock runs ahead would otherwise issue commands that
        // never grow old.
        XCTAssertFalse(envelope.isFresh(now: now))
    }

    func testSmallClockSkewIsTolerated() {
        let now = Date()
        let envelope = RemoteCommandEnvelope(
            command: .decide(requestID: "toolu_01", allow: true, remember: false),
            issuedAt: now.addingTimeInterval(5)
        )
        // Two devices are never in perfect step; a few seconds of disagreement
        // must not be treated as an attack.
        XCTAssertTrue(envelope.isFresh(now: now))
    }

    // MARK: - Codifica

    func testCommandSurvivesTheRoundTrip() throws {
        let original = RemoteCommandEnvelope(
            command: .decide(requestID: "toolu_99", allow: false, remember: true),
            issuedAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
        let data = try Wire.encoder.encode(original)
        let restored = try Wire.decoder.decode(RemoteCommandEnvelope.self, from: data)
        XCTAssertEqual(restored, original)
    }

    func testSubSecondPrecisionIsNotPreserved() throws {
        // Documented rather than fixed. A `Date` carrying fractions does not
        // come back bit-identical through JSON, so the wire is only accurate to
        // the second — which is all the freshness window needs, and far less
        // than the clock skew between two devices anyway.
        //
        // It is written down because the alternative is discovering it as an
        // equality check that fails on two values printing the same.
        let precise = Date(timeIntervalSince1970: 1_787_000_000.123456)
        let restored = try Wire.decoder.decode(
            Date.self,
            from: try Wire.encoder.encode(precise)
        )
        XCTAssertEqual(
            restored.timeIntervalSince1970,
            precise.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testDatesTravelAsEpochSeconds() throws {
        // A regression guard, not a style check. `JSONEncoder`'s default writes
        // seconds since 2001, which reads as a plausible date roughly thirty
        // years off — the kind of wrong that survives review.
        struct Sample: Codable { let at: Date }
        let data = try Wire.encoder.encode(Sample(at: Date(timeIntervalSince1970: 1_787_000_000)))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"at":1787000000}"#)
    }

    func testSnapshotCarriesItsVersion() throws {
        let snapshot = RemoteSnapshot(
            usage: nil, projects: [], sessions: [], alert: nil, generatedAt: Date()
        )
        XCTAssertEqual(snapshot.version, RemoteSnapshot.currentVersion)

        let restored = try Wire.decoder.decode(
            RemoteSnapshot.self,
            from: try Wire.encoder.encode(snapshot)
        )
        // An app meeting a Mac that speaks a later dialect has to be able to see
        // that it does, rather than decode part of it and show the rest wrong.
        XCTAssertEqual(restored.version, RemoteSnapshot.currentVersion)
    }

    // MARK: - Modelli di dominio sul filo

    func testSessionKeepsWhatMattersAcrossTheWire() throws {
        let session = ClaudeSessionStatus(json: [
            "project_path": "/Users/x/repo",
            "state": "waiting_input",
            "session_id": "s1",
            "request_id": "toolu_01",
            "tool_summary": "rm -rf build",
            "decidable": true,
            "updated_at_epoch": 1_787_000_000.0,
        ])!

        let restored = try Wire.decoder.decode(
            ClaudeSessionStatus.self,
            from: try Wire.encoder.encode(session)
        )

        XCTAssertEqual(restored, session)
        // The fields the Allow/Deny buttons depend on: without these the phone
        // shows a request it cannot actually answer.
        XCTAssertEqual(restored.requestID, "toolu_01")
        XCTAssertEqual(restored.toolSummary, "rm -rf build")
        XCTAssertTrue(restored.isDecidable)
    }
}
