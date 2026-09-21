import AppKit
import MascotCore

/// I fotogrammi di una mascotte, già ritagliati e pronti da mostrare.
///
/// Ritagliati una volta sola al caricamento e tenuti in memoria: sono una
/// ventina di quadratini da 96 punti, meno di quanto costi una sola icona di
/// grandi dimensioni, e ritagliarli a ogni fotogramma vorrebbe dire fare lavoro
/// di grafica dieci volte al secondo per sempre.
struct MascotSprites {
    let manifest: MascotManifest
    private let frames: [NSImage]

    /// Quanti fotogrammi sono stati trovati davvero.
    var count: Int { frames.count }

    func frame(at index: Int) -> NSImage? {
        guard frames.indices.contains(index) else { return nil }
        return frames[index]
    }

    /// Il primo fotogramma di uno stato: l'anteprima di una mascotte, e il
    /// disegno su cui si riposa quando non c'è niente da animare.
    func firstFrame(of state: MascotState) -> NSImage? {
        frame(at: manifest.animation(for: state).frames.first ?? 0)
    }

    enum LoadError: Error, CustomStringConvertible {
        case manifestUnreadable(URL)
        case manifestInvalid(String)
        case imageMissing(URL)
        case tooFewFrames(found: Int, required: Int)

        var description: String {
            switch self {
            case .manifestUnreadable(let url):
                return "mascot.json non leggibile in \(url.path)"
            case .manifestInvalid(let why):
                return why
            case .imageMissing(let url):
                return "immagine mancante: \(url.lastPathComponent)"
            case .tooFewFrames(let found, let required):
                return "il foglio ha \(found) fotogrammi, il manifesto ne usa \(required)"
            }
        }
    }

    /// Carica una cartella-mascotte: `mascot.json` più i disegni che dichiara.
    static func load(from folder: URL) throws -> MascotSprites {
        let manifestURL = folder.appendingPathComponent("mascot.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw LoadError.manifestUnreadable(manifestURL)
        }

        let manifest: MascotManifest
        do {
            manifest = try MascotManifest.decode(data, fallbackID: folder.lastPathComponent)
        } catch {
            throw LoadError.manifestInvalid("\(folder.lastPathComponent): \(error)")
        }

        let frames: [NSImage]
        switch manifest.source {
        case .sheet(let file, let columns):
            frames = try sliceSheet(
                at: folder.appendingPathComponent(file),
                frameSize: manifest.frameSize,
                columns: columns
            )
        case .sequence(let name):
            frames = try loadSequence(
                from: folder.appendingPathComponent(name, isDirectory: true),
                frameSize: manifest.frameSize
            )
        }

        guard frames.count >= manifest.requiredFrameCount else {
            throw LoadError.tooFewFrames(found: frames.count, required: manifest.requiredFrameCount)
        }

        return MascotSprites(manifest: manifest, frames: frames)
    }

    // MARK: - Foglio di sprite

    private static func sliceSheet(
        at url: URL, frameSize: CGSize, columns declared: Int?
    ) throws -> [NSImage] {
        guard let source = NSImage(contentsOf: url),
              let sheet = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw LoadError.imageMissing(url) }

        // Il foglio può essere disegnato più fitto di quanto misura in punti —
        // è come si fa una mascotte nitida su schermo Retina. In quel caso le
        // colonne vanno dichiarate, perché altrimenti la stessa immagine si
        // legge sia come «larga il doppio» sia come «con il doppio delle
        // colonne» e non c'è modo di sapere quale delle due.
        let columns = declared ?? max(1, Int(CGFloat(sheet.width) / frameSize.width))
        let scale = CGFloat(sheet.width) / (CGFloat(columns) * frameSize.width)
        let cell = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        guard cell.width >= 1, cell.height >= 1 else {
            throw LoadError.tooFewFrames(found: 0, required: 1)
        }

        let rows = max(1, Int(CGFloat(sheet.height) / cell.height))
        var frames: [NSImage] = []
        frames.reserveCapacity(rows * columns)

        for row in 0..<rows {
            for column in 0..<columns {
                // `CGImage` conta le righe dall'alto, che è anche l'ordine in cui
                // un foglio di sprite si legge: prima cella in alto a sinistra.
                let rect = CGRect(
                    x: CGFloat(column) * cell.width,
                    y: CGFloat(row) * cell.height,
                    width: cell.width,
                    height: cell.height
                )
                guard let cropped = sheet.cropping(to: rect) else { continue }
                // La dimensione *in punti* resta quella dichiarata: così un
                // foglio più fitto diventa una mascotte più nitida, non più
                // grande.
                frames.append(NSImage(cgImage: cropped, size: frameSize))
            }
        }
        return frames
    }

    // MARK: - Sequenza di PNG numerati

    private static func loadSequence(from folder: URL, frameSize: CGSize) throws -> [NSImage] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? []

        // In ordine di nome, e con un confronto numerico: altrimenti `10.png`
        // finisce fra `1.png` e `2.png`, e l'animazione va a scatti sbagliati.
        let ordered = files
            .filter { ["png", "PNG"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !ordered.isEmpty else { throw LoadError.imageMissing(folder) }

        return ordered.compactMap { url in
            guard let image = NSImage(contentsOf: url) else { return nil }
            image.size = frameSize
            return image
        }
    }
}
