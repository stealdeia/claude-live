import XCTest
@testable import MascotCore

/// Il manifesto è il punto in cui entra roba scritta da qualcun altro: la
/// mascotte che l'utente si disegna arriva da una cartella sua, con un JSON suo.
/// Quindi le prove sono due cose insieme — che un file giusto venga letto come
/// ci si aspetta, e che un file sbagliato dica *cosa* ha di sbagliato invece di
/// far sparire la mascotte in silenzio.
final class MascotManifestTests: XCTestCase {
    private func manifest(_ json: String) throws -> MascotManifest {
        try MascotManifest.decode(Data(json.utf8))
    }

    private let minimal = """
    {
      "id": "prova",
      "frameWidth": 96,
      "frameHeight": 96,
      "sheet": "sprites.png",
      "states": { "idle": { "frames": "0-3" } }
    }
    """

    func testLetturaMinima() throws {
        let m = try manifest(minimal)
        XCTAssertEqual(m.id, "prova")
        // Senza nome, il nome è l'identificativo: una mascotte senza etichetta
        // nel menu sarebbe una voce vuota da scegliere.
        XCTAssertEqual(m.name, "prova")
        XCTAssertEqual(m.frameSize, CGSize(width: 96, height: 96))
        XCTAssertEqual(m.source, .sheet(file: "sprites.png", columns: nil))
        XCTAssertEqual(m.animation(for: .idle).frames, [0, 1, 2, 3])
        XCTAssertEqual(m.animation(for: .idle).fps, MascotManifest.defaultFPS)
        XCTAssertTrue(m.animation(for: .idle).loops)
    }

    func testFileVeroDellaMascotteInclusa() throws {
        // Il manifesto che lo script genera davvero: se cambia il formato, questa
        // prova è la prima a saperlo.
        let m = try manifest("""
        {
          "schema": 1, "id": "bolla", "name": "Bolla", "author": "Vibing Code Live",
          "frameWidth": 96, "frameHeight": 96, "fps": 8,
          "sheet": "sprites.png", "columns": 8,
          "states": {
            "idle": { "frames": "0-3", "fps": 5, "loop": true },
            "working": { "frames": "4-7", "fps": 10, "loop": true },
            "notify": { "frames": "8-13", "fps": 12, "loop": false, "next": "idle" },
            "dragging": { "frames": "14-15", "fps": 8, "loop": true },
            "dropped": { "frames": "16-17", "fps": 10, "loop": false, "next": "idle" },
            "sleeping": { "frames": "18-21", "fps": 3, "loop": true }
          }
        }
        """)
        XCTAssertEqual(m.name, "Bolla")
        XCTAssertEqual(m.source, .sheet(file: "sprites.png", columns: 8))
        XCTAssertEqual(m.animations.count, MascotState.allCases.count)
        XCTAssertEqual(m.animation(for: .notify).next, .idle)
        XCTAssertFalse(m.animation(for: .notify).loops)
        // 22 celle: il foglio deve averle tutte.
        XCTAssertEqual(m.requiredFrameCount, 22)
    }

    // MARK: - I fotogrammi, nei tre modi in cui viene da scriverli

    func testFotogrammiComeIntervallo() throws {
        XCTAssertEqual(try manifest(minimal).animation(for: .idle).frames, [0, 1, 2, 3])
    }

    func testFotogrammiComeElenco() throws {
        let m = try manifest(minimal.replacingOccurrences(of: "\"0-3\"", with: "[4, 2, 4, 9]"))
        // L'ordine è quello scritto, non riordinato: un'animazione che va avanti
        // e indietro si scrive così.
        XCTAssertEqual(m.animation(for: .idle).frames, [4, 2, 4, 9])
    }

    func testFotogrammaSingolo() throws {
        let m = try manifest(minimal.replacingOccurrences(of: "\"0-3\"", with: "7"))
        XCTAssertEqual(m.animation(for: .idle).frames, [7])
        // Un fotogramma solo è un disegno fermo: chi lo riproduce non deve
        // accendere nessun timer.
        XCTAssertTrue(m.animation(for: .idle).isStill)
    }

    func testIntervalliMisti() throws {
        let m = try manifest(minimal.replacingOccurrences(of: "\"0-3\"", with: "\"0-2, 8, 10-11\""))
        XCTAssertEqual(m.animation(for: .idle).frames, [0, 1, 2, 8, 10, 11])
    }

    func testIntervalloAllaRovesciaEUnErrore() {
        XCTAssertThrowsError(
            try manifest(minimal.replacingOccurrences(of: "\"0-3\"", with: "\"5-2\""))
        ) { error in
            XCTAssertEqual(error as? MascotManifestError, .badFrames(state: "idle", value: "5-2"))
        }
    }

    func testFotogrammiNegativiSonoUnErrore() {
        XCTAssertThrowsError(
            try manifest(minimal.replacingOccurrences(of: "\"0-3\"", with: "[0, -2]"))
        )
    }

    // MARK: - Quello che manca

    func testSenzaIdleNonSiCarica() {
        let json = minimal.replacingOccurrences(of: "\"idle\"", with: "\"working\"")
        XCTAssertThrowsError(try manifest(json)) { error in
            XCTAssertEqual(error as? MascotManifestError, .missingIdle)
        }
    }

    func testSenzaSorgenteNonSiCarica() {
        let json = minimal.replacingOccurrences(of: "\"sheet\": \"sprites.png\",", with: "")
        XCTAssertThrowsError(try manifest(json)) { error in
            XCTAssertEqual(error as? MascotManifestError, .noSource)
        }
    }

    func testMisuraDelFotogrammaAZeroNonSiCarica() {
        let json = minimal.replacingOccurrences(of: "\"frameWidth\": 96", with: "\"frameWidth\": 0")
        XCTAssertThrowsError(try manifest(json)) { error in
            XCTAssertEqual(error as? MascotManifestError, .invalidFrameSize)
        }
    }

    func testNonJSON() {
        XCTAssertThrowsError(try manifest("questo non è json")) { error in
            XCTAssertEqual(error as? MascotManifestError, .notJSON)
        }
    }

    func testRimandoAUnoStatoInesistente() {
        let json = minimal.replacingOccurrences(
            of: "{ \"frames\": \"0-3\" }",
            with: "{ \"frames\": \"0-3\", \"next\": \"ballando\" }"
        )
        XCTAssertThrowsError(try manifest(json)) { error in
            XCTAssertEqual(error as? MascotManifestError, .unknownNext(state: "idle", next: "ballando"))
        }
    }

    /// Una mascotte disegnata per una versione futura, con uno stato che questa
    /// non conosce, deve restare usabile: lo stato di troppo si ignora.
    func testStatiSconosciutiVengonoIgnorati() throws {
        let json = minimal.replacingOccurrences(
            of: "\"idle\": { \"frames\": \"0-3\" }",
            with: "\"idle\": { \"frames\": \"0-3\" }, \"ballando\": { \"frames\": \"9-12\" }"
        )
        let m = try manifest(json)
        XCTAssertEqual(m.animations.count, 1)
    }

    /// Uno stato non disegnato ricade su `idle`, invece di lasciare la mascotte
    /// senza niente da mostrare.
    func testStatoMancanteRicadeSuIdle() throws {
        let m = try manifest(minimal)
        XCTAssertEqual(m.animation(for: .sleeping).frames, m.animation(for: .idle).frames)
    }

    // MARK: - Velocità

    func testVelocitaFuoriScalaVieneRiportataDentro() throws {
        let fast = minimal.replacingOccurrences(
            of: "{ \"frames\": \"0-3\" }", with: "{ \"frames\": \"0-3\", \"fps\": 600 }"
        )
        XCTAssertEqual(try manifest(fast).animation(for: .idle).fps, MascotManifest.fpsRange.upperBound)

        let stopped = minimal.replacingOccurrences(
            of: "{ \"frames\": \"0-3\" }", with: "{ \"frames\": \"0-3\", \"fps\": 0 }"
        )
        XCTAssertEqual(try manifest(stopped).animation(for: .idle).fps, MascotManifest.fpsRange.lowerBound)
    }

    func testVelocitaGeneraleValePerGliStatiCheNonLaDichiarano() throws {
        let json = """
        {
          "id": "prova", "frameWidth": 32, "frameHeight": 32, "fps": 12,
          "sequence": "frames",
          "states": {
            "idle": { "frames": "0-1" },
            "notify": { "frames": "2-3", "fps": 4 }
          }
        }
        """
        let m = try manifest(json)
        XCTAssertEqual(m.animation(for: .idle).fps, 12)
        XCTAssertEqual(m.animation(for: .notify).fps, 4)
        XCTAssertEqual(m.source, .sequence(folder: "frames"))
    }

    // MARK: - Avanzamento

    func testAnimazioneCiclicaTornaAlPrimoFotogramma() throws {
        let idle = try manifest(minimal).animation(for: .idle)
        XCTAssertEqual(idle.position(after: 0), 1)
        XCTAssertEqual(idle.position(after: 3), 0)
    }

    func testAnimazioneNonCiclicaFinisce() throws {
        let json = minimal.replacingOccurrences(
            of: "{ \"frames\": \"0-3\" }", with: "{ \"frames\": \"0-3\", \"loop\": false }"
        )
        let once = try manifest(json).animation(for: .idle)
        XCTAssertEqual(once.position(after: 2), 3)
        XCTAssertNil(once.position(after: 3))
    }
}
