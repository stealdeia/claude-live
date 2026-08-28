import XCTest
@testable import ClaudeLiveKit

/// «Non c'è» e «non si può leggere adesso» non sono la stessa risposta.
///
/// Perché esistono queste prove: spegnendo e riaccendendo il telefono, l'app
/// chiedeva di rifare il codice QR. Le chiavi non erano andate perdute — prima
/// del primo sblocco dopo un riavvio il portachiavi esiste ma non risponde, e
/// quel silenzio veniva letto come «non sei accoppiato». La decisione veniva poi
/// presa una volta sola all'avvio, quindi restava sbagliata anche dopo lo sblocco.
final class PairingLookupTests: XCTestCase {

    private func check(
        _ pairID: RemoteSecrets.Lookup,
        _ key: RemoteSecrets.Lookup,
        _ relay: RemoteSecrets.Lookup,
        legacy: String? = nil
    ) -> Bool? {
        RemoteSecrets.pairingIsComplete(
            pairID: pairID, encryptionKey: key, relayURL: relay, legacyRelayURL: legacy
        )
    }

    private let id = RemoteSecrets.Lookup.found("0123456789abcdef0123456789abcdef")
    private let key = RemoteSecrets.Lookup.found("chiave")
    private let url = RemoteSecrets.Lookup.found("https://relay.example")
    private let locked = RemoteSecrets.Lookup.unavailable(errSecInteractionNotAllowed)

    func testEverythingThereIsPaired() {
        XCTAssertEqual(check(id, key, url), true)
    }

    func testANewInstallIsNotPaired() {
        XCTAssertEqual(check(.absent, .absent, .absent), false)
    }

    /// Il difetto, nella sua forma esatta.
    func testALockedPhoneAnswersNothing() {
        XCTAssertNil(check(locked, locked, locked),
                     "telefono bloccato: la risposta è «non lo so», non «no»")
    }

    /// Anche uno solo dei tre illeggibile basta a non concludere.
    func testOneUnreadableItemIsEnoughToWithholdJudgement() {
        XCTAssertNil(check(locked, key, url))
        XCTAssertNil(check(id, locked, url))
        XCTAssertNil(check(id, key, locked))
    }

    /// Ma un'assenza vera resta un no, anche accanto a un illeggibile: mezzo
    /// accoppiamento non è un accoppiamento, e su questo non c'è dubbio da avere.
    func testAGenuineAbsenceStillMeansNo() {
        XCTAssertEqual(check(.absent, locked, url), false)
        XCTAssertEqual(check(id, .absent, url), false)
    }

    /// Chi aveva l'app prima che l'indirizzo si trasferisse nel portachiavi.
    func testTheOldAddressStillCounts() {
        XCTAssertEqual(check(id, key, .absent, legacy: "https://relay.example"), true)
        XCTAssertEqual(check(id, key, .absent, legacy: ""), false)
        XCTAssertEqual(check(id, key, .absent, legacy: nil), false)
    }

    /// Una voce vuota è una voce che non serve: senza indirizzo non si pubblica.
    func testAnEmptyValueIsNotAnAnswer() {
        XCTAssertEqual(check(.found(""), key, url), false)
        XCTAssertEqual(check(id, key, .found("")), false)
    }
}
