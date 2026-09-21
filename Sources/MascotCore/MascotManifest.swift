import CoreGraphics
import Foundation

/// Quello che la mascotte può stare facendo.
///
/// Elenco chiuso e non stringhe libere: gli stati non sono un dettaglio del
/// disegno, sono il patto fra l'app e la cartella di una mascotte. Una mascotte
/// che inventasse uno stato suo non avrebbe niente che glielo fa succedere, e
/// una che ne dimenticasse uno lascerebbe un buco che si vede solo il giorno in
/// cui quello stato serve — per questo manca solo `idle` è un errore, e tutti
/// gli altri ricadono su di lui.
public enum MascotState: String, Codable, CaseIterable, Sendable {
    /// Ferma: il respiro lento, con le sue variazioni ogni tanto.
    case idle
    /// Claude Code sta lavorando in qualche progetto.
    case working
    /// È appena successo qualcosa: salta e si sbraccia, poi torna `idle`.
    case notify
    /// In mano, mentre la si trascina.
    case dragging
    /// Appena atterrata dopo un trascinamento.
    case dropped
    /// Dorme, dopo un po' che non succede niente.
    case sleeping

    public var label: String {
        switch self {
        case .idle: return "Ferma"
        case .working: return "Al lavoro"
        case .notify: return "Avviso"
        case .dragging: return "In mano"
        case .dropped: return "Atterraggio"
        case .sleeping: return "Addormentata"
        }
    }
}

/// Un'animazione: quali celle del foglio, a che velocità, e cosa succede dopo.
public struct MascotAnimation: Equatable, Sendable {
    public let state: MascotState
    /// Indici delle celle, nell'ordine in cui vanno mostrate.
    public let frames: [Int]
    public let fps: Double
    public let loops: Bool
    /// Dove andare quando un'animazione non ciclica finisce.
    public let next: MascotState?

    public init(state: MascotState, frames: [Int], fps: Double, loops: Bool, next: MascotState?) {
        self.state = state
        self.frames = frames
        self.fps = fps
        self.loops = loops
        self.next = next
    }

    /// Quanto dura un fotogramma.
    public var frameDuration: TimeInterval { 1 / fps }

    /// Un'animazione di un fotogramma solo non ha niente da animare: è un
    /// disegno fermo, e chi la riproduce non deve accendere nessun timer. È il
    /// motivo per cui `sleeping` può costare zero.
    public var isStill: Bool { frames.count <= 1 }

    /// La posizione successiva dentro `frames`, o `nil` se l'animazione è
    /// finita — cosa che può capitare solo se non è ciclica.
    public func position(after position: Int) -> Int? {
        let next = position + 1
        if next < frames.count { return next }
        return loops ? 0 : nil
    }
}

/// Il manifesto di una mascotte: `mascot.json` dentro la sua cartella.
public struct MascotManifest: Equatable, Sendable {
    /// Da dove arrivano i fotogrammi.
    public enum Source: Equatable, Sendable {
        /// Un unico PNG a griglia di celle uguali. `columns` può mancare: in tal
        /// caso lo si ricava dalla larghezza dell'immagine.
        case sheet(file: String, columns: Int?)
        /// Una cartella di PNG numerati, in ordine di nome.
        case sequence(folder: String)
    }

    public let id: String
    public let name: String
    public let author: String?
    public let frameSize: CGSize
    public let source: Source
    public let animations: [MascotState: MascotAnimation]

    public init(
        id: String,
        name: String,
        author: String?,
        frameSize: CGSize,
        source: Source,
        animations: [MascotState: MascotAnimation]
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.frameSize = frameSize
        self.source = source
        self.animations = animations
    }

    /// L'animazione di uno stato, o quella di `idle`.
    ///
    /// Non è un ripiego di comodo: una mascotte disegnata da qualcun altro può
    /// legittimamente non avere un'animazione del sonno, e restare ferma è una
    /// risposta ragionevole. Restare *senza niente da mostrare* no.
    public func animation(for state: MascotState) -> MascotAnimation {
        animations[state] ?? animations[.idle] ?? MascotAnimation(
            state: .idle, frames: [0], fps: 1, loops: false, next: nil
        )
    }

    /// Il numero di celle che il foglio deve avere per soddisfare il manifesto.
    /// Serve a chi carica l'immagine per accorgersi subito se è troppo corta.
    public var requiredFrameCount: Int {
        (animations.values.flatMap(\.frames).max() ?? 0) + 1
    }
}

public enum MascotManifestError: Error, Equatable, CustomStringConvertible {
    case notJSON
    case missingField(String)
    case invalidFrameSize
    case noSource
    case noStates
    case missingIdle
    case badFrames(state: String, value: String)
    case unknownNext(state: String, next: String)

    public var description: String {
        switch self {
        case .notJSON:
            return "mascot.json non è un JSON valido"
        case .missingField(let name):
            return "manca il campo «\(name)»"
        case .invalidFrameSize:
            return "frameWidth e frameHeight devono essere maggiori di zero"
        case .noSource:
            return "manca «sheet» (foglio di sprite) o «sequence» (cartella di PNG numerati)"
        case .noStates:
            return "manca il campo «states»"
        case .missingIdle:
            return "manca lo stato «idle», che è quello su cui ripiegano tutti gli altri"
        case .badFrames(let state, let value):
            return "i fotogrammi di «\(state)» non si leggono: «\(value)»"
        case .unknownNext(let state, let next):
            return "«\(state)» rimanda a uno stato che non esiste: «\(next)»"
        }
    }
}

extension MascotManifest {
    /// Velocità ammesse. L'animazione è a scatti per scelta, ma un manifesto con
    /// uno zero o un 600 di troppo non deve poter fermare la mascotte né
    /// scaldare il Mac: si riporta dentro invece di rifiutare il file, perché
    /// una mascotte scritta a mano da qualcuno vale più di un errore formale.
    public static let fpsRange: ClosedRange<Double> = 1...30
    public static let defaultFPS: Double = 8

    /// Legge un `mascot.json`.
    ///
    /// Scritto a mano invece che con `Codable` per intero perché gli errori sono
    /// metà del lavoro: questo file lo scriverà anche chi si disegna la propria
    /// mascotte, e «i fotogrammi di notify non si leggono» è un'informazione,
    /// mentre `keyNotFound(CodingKeys(...))` no.
    public static func decode(_ data: Data, fallbackID: String? = nil) throws -> MascotManifest {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MascotManifestError.notJSON
        }

        let id = (root["id"] as? String) ?? fallbackID
        guard let id, !id.isEmpty else { throw MascotManifestError.missingField("id") }
        let name = (root["name"] as? String) ?? id

        let width = number(root["frameWidth"])
        let height = number(root["frameHeight"])
        guard let width, let height, width > 0, height > 0 else {
            throw MascotManifestError.invalidFrameSize
        }

        let source: Source
        if let sheet = root["sheet"] as? String, !sheet.isEmpty {
            let columns = number(root["columns"]).map { Int($0) }
            source = .sheet(file: sheet, columns: columns.flatMap { $0 > 0 ? $0 : nil })
        } else if let sequence = root["sequence"] as? String, !sequence.isEmpty {
            source = .sequence(folder: sequence)
        } else {
            throw MascotManifestError.noSource
        }

        guard let states = root["states"] as? [String: Any], !states.isEmpty else {
            throw MascotManifestError.noStates
        }

        let defaultFPS = (number(root["fps"]) ?? defaultFPS).clampedFPS

        var animations: [MascotState: MascotAnimation] = [:]
        for (key, value) in states {
            // Uno stato che non conosciamo viene ignorato invece di far fallire
            // il file: è così che una mascotte scritta per una versione futura
            // resta usabile da questa.
            guard let state = MascotState(rawValue: key) else { continue }
            guard let entry = value as? [String: Any] else {
                throw MascotManifestError.badFrames(state: key, value: "\(value)")
            }

            let raw = entry["frames"] ?? entry["frame"]
            guard let frames = parseFrames(raw), !frames.isEmpty else {
                throw MascotManifestError.badFrames(state: key, value: describe(raw))
            }

            var next: MascotState?
            if let rawNext = entry["next"] as? String {
                guard let parsed = MascotState(rawValue: rawNext) else {
                    throw MascotManifestError.unknownNext(state: key, next: rawNext)
                }
                next = parsed
            }

            animations[state] = MascotAnimation(
                state: state,
                frames: frames,
                fps: (number(entry["fps"]) ?? defaultFPS).clampedFPS,
                // Cicliche per default: è quello che fa la maggior parte degli
                // stati, e dimenticarsi `loop` su `idle` la fermerebbe.
                loops: (entry["loop"] as? Bool) ?? true,
                next: next
            )
        }

        guard animations[.idle] != nil else { throw MascotManifestError.missingIdle }

        return MascotManifest(
            id: id,
            name: name,
            author: root["author"] as? String,
            frameSize: CGSize(width: width, height: height),
            source: source,
            animations: animations
        )
    }

    /// I fotogrammi si possono scrivere in tre modi, perché tre sono i modi in
    /// cui viene spontaneo scriverli: `"0-3"`, `[0, 1, 2, 3]`, `5`. Anche
    /// `"0-3, 8, 10-11"`, per gli stati che riusano una posa.
    static func parseFrames(_ raw: Any?) -> [Int]? {
        switch raw {
        case let list as [Any]:
            let numbers = list.compactMap { number($0).map(Int.init) }
            guard numbers.count == list.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
            return numbers
        case let single as NSNumber:
            let value = single.intValue
            return value >= 0 ? [value] : nil
        case let text as String:
            var frames: [Int] = []
            for piece in text.split(separator: ",") {
                let part = piece.trimmingCharacters(in: .whitespaces)
                if part.isEmpty { return nil }
                let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                switch bounds.count {
                case 1:
                    guard let value = Int(bounds[0]), value >= 0 else { return nil }
                    frames.append(value)
                case 2:
                    guard let from = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
                          let to = Int(bounds[1].trimmingCharacters(in: .whitespaces)),
                          from >= 0, to >= from
                    else { return nil }
                    frames.append(contentsOf: from...to)
                default:
                    return nil
                }
            }
            return frames.isEmpty ? nil : frames
        default:
            return nil
        }
    }

    private static func number(_ raw: Any?) -> Double? {
        // `as? Double` da solo non prende gli interi del JSON, e `as? Int` non
        // prende i decimali: NSNumber li copre entrambi.
        (raw as? NSNumber)?.doubleValue
    }

    private static func describe(_ raw: Any?) -> String {
        guard let raw else { return "assente" }
        return "\(raw)"
    }
}

private extension Double {
    var clampedFPS: Double {
        min(max(self, MascotManifest.fpsRange.lowerBound), MascotManifest.fpsRange.upperBound)
    }
}
