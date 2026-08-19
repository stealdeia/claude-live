import XCTest
import CryptoKit
@testable import ClaudeLiveKit

/// The first automated tests in this project, and they are here rather than
/// anywhere else for a reason: encryption fails silently. A panel that draws the
/// wrong colour is noticed in a second; a payload that is not really protected
/// looks exactly like one that is.
final class RemoteCryptoTests: XCTestCase {

    // MARK: - Chiavi

    func testKeySurvivesExportAndImport() throws {
        let key = RemoteCrypto.newKey()
        let restored = try RemoteCrypto.importKey(RemoteCrypto.export(key))

        // Compared through a sealed box: `SymmetricKey` equality would compare
        // the objects, and what matters is that the restored key still opens
        // what the original sealed.
        let sealed = try RemoteCrypto.seal(["ciao"], with: key)
        XCTAssertEqual(try RemoteCrypto.open([String].self, from: sealed, with: restored), ["ciao"])
    }

    func testKeyOfTheWrongLengthIsRefused() {
        // 16 bytes: a plausible key, and half of one.
        let short = Data(repeating: 0, count: 16).base64EncodedString()
        XCTAssertThrowsError(try RemoteCrypto.importKey(short)) { error in
            XCTAssertEqual(error as? RemoteCrypto.Failure, .malformedKey)
        }
    }

    func testKeyThatIsNotBase64IsRefused() {
        XCTAssertThrowsError(try RemoteCrypto.importKey("non sono una chiave")) { error in
            XCTAssertEqual(error as? RemoteCrypto.Failure, .malformedKey)
        }
    }

    // MARK: - Andata e ritorno

    func testSnapshotSurvivesTheRoundTrip() throws {
        let key = RemoteCrypto.newKey()
        let snapshot = Self.sampleSnapshot()

        let sealed = try RemoteCrypto.seal(snapshot, with: key)
        let opened = try RemoteCrypto.open(RemoteSnapshot.self, from: sealed, with: key)

        XCTAssertEqual(opened, snapshot)
    }

    func testSealedPayloadDoesNotLeakItsContents() throws {
        let key = RemoteCrypto.newKey()
        let snapshot = Self.sampleSnapshot()

        let sealed = try RemoteCrypto.seal(snapshot, with: key)

        // The whole point of the relay being untrusted: a project path is the
        // kind of thing that must not be readable in transit.
        XCTAssertFalse(sealed.contains("progetto-segreto"))
        if let decoded = Data(base64Encoded: sealed) {
            XCTAssertFalse(String(decoding: decoded, as: UTF8.self).contains("progetto-segreto"))
        }
    }

    // MARK: - Quando deve fallire

    func testWrongKeyCannotOpen() throws {
        let sealed = try RemoteCrypto.seal(Self.sampleSnapshot(), with: RemoteCrypto.newKey())

        XCTAssertThrowsError(
            try RemoteCrypto.open(RemoteSnapshot.self, from: sealed, with: RemoteCrypto.newKey())
        ) { error in
            XCTAssertEqual(error as? RemoteCrypto.Failure, .couldNotOpen)
        }
    }

    func testAlteredPayloadIsRejected() throws {
        let key = RemoteCrypto.newKey()
        let sealed = try RemoteCrypto.seal(Self.sampleSnapshot(), with: key)

        var bytes = Data(base64Encoded: sealed)!
        // Flip one bit in the ciphertext, past the 12-byte nonce. This is the
        // test that matters: it is what separates encryption from authenticated
        // encryption, and without the check a relay could edit what it forwards.
        bytes[bytes.count - 20] ^= 0x01

        XCTAssertThrowsError(
            try RemoteCrypto.open(
                RemoteSnapshot.self,
                from: bytes.base64EncodedString(),
                with: key
            )
        ) { error in
            XCTAssertEqual(error as? RemoteCrypto.Failure, .couldNotOpen)
        }
    }

    func testGarbageIsRejectedWithoutCrashing() {
        let key = RemoteCrypto.newKey()
        XCTAssertThrowsError(
            try RemoteCrypto.open(RemoteSnapshot.self, from: "@@@ non base64 @@@", with: key)
        ) { error in
            XCTAssertEqual(error as? RemoteCrypto.Failure, .malformedPayload)
        }
    }

    func testTooShortToBeASealedBoxIsRejected() {
        let key = RemoteCrypto.newKey()
        let tooShort = Data([1, 2, 3]).base64EncodedString()
        XCTAssertThrowsError(
            try RemoteCrypto.open(RemoteSnapshot.self, from: tooShort, with: key)
        ) { error in
            XCTAssertEqual(error as? RemoteCrypto.Failure, .malformedPayload)
        }
    }

    // MARK: - Materiale

    private static func sampleSnapshot() -> RemoteSnapshot {
        let session = ClaudeSessionStatus(json: [
            "project_path": "/Users/x/progetto-segreto",
            "project_name": "progetto-segreto",
            "session_id": "abc123def456",
            "state": "waiting_input",
            "event": "PermissionRequest",
            "request_kind": "permission",
            "request_id": "toolu_01",
            "tool_name": "Bash",
            "tool_summary": "npm test",
            "decidable": true,
            "updated_at_epoch": 1_787_000_000.0,
        ])!

        return RemoteSnapshot(
            usage: UsageSnapshot(
                fiveHour: UsageWindow(utilization: 0.17, resetAt: nil, status: "allowed"),
                sevenDay: UsageWindow(utilization: 0.40, resetAt: nil, status: "allowed"),
                opusSevenDay: nil,
                representativeClaim: "five_hour",
                overallStatus: "allowed",
                fetchedAt: Date(timeIntervalSince1970: 1_787_000_000),
                httpStatus: 200,
                subscriptionType: "max"
            ),
            projects: [
                ClaudeProjectStatus(
                    projectPath: "/Users/x/progetto-segreto",
                    state: .waitingInput,
                    detail: "Bash",
                    requestKind: "permission",
                    updatedAt: Date(timeIntervalSince1970: 1_787_000_000),
                    sessionCount: 1,
                    isStale: false
                )
            ],
            sessions: [session],
            alert: ClaudeAlert(
                kind: .waiting,
                projectPath: "/Users/x/progetto-segreto",
                projectName: "progetto-segreto",
                sessionID: "abc123def456",
                raisedAt: Date(timeIntervalSince1970: 1_787_000_000),
                detail: "npm test"
            ),
            generatedAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
    }
}
