import AppKit
import Combine
import MascotCore

/// Le mascotte disponibili: quelle incluse nell'app e, più avanti, quella che
/// l'utente si è disegnato.
///
/// Carica tutto subito, al primo giro: sono una manciata di cartelle con una
/// ventina di quadratini ciascuna, e averle già pronte è ciò che permette al
/// selettore delle Impostazioni di mostrare le anteprime senza rileggere il
/// disco mentre l'utente scorre.
@MainActor
final class MascotStore: ObservableObject {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let author: String?
        let folder: URL
        /// Inclusa nell'app, invece che scelta dall'utente.
        let isBuiltIn: Bool
        let sprites: MascotSprites

        /// Come si presenta nell'elenco: il primo fotogramma da ferma.
        var preview: NSImage? { sprites.firstFrame(of: .idle) }
    }

    @Published private(set) var entries: [Entry] = []

    private let settings: Settings
    private var cancellables: Set<AnyCancellable> = []

    /// La cartella con le mascotte incluse, dentro il bundle.
    ///
    /// `build.sh` ci copia dentro `Resources/Mascots`. Eseguendo il binario
    /// nudo, fuori dal bundle, la cartella non c'è: la mascotte non si accende e
    /// il log dice perché, invece di lasciare una finestrella vuota sullo
    /// schermo.
    static var bundledFolder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Mascots", isDirectory: true)
    }

    init(settings: Settings) {
        self.settings = settings
        reload()

        settings.$mascotCustomPath
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
            .store(in: &cancellables)
    }

    /// Rilegge le cartelle: quelle incluse più, se c'è, quella scelta dall'utente.
    func reload() {
        var found: [Entry] = []

        if let bundled = Self.bundledFolder {
            found += load(from: bundled, isBuiltIn: true)
        }

        if let path = settings.mascotCustomPath, !path.isEmpty {
            let folder = URL(fileURLWithPath: path)
            if let custom = loadOne(folder: folder, isBuiltIn: false) {
                // Se ha lo stesso identificativo di una inclusa vince la sua:
                // l'ha scelta lei, e ritrovarsi il personaggio di serie dopo
                // averne indicato un altro sarebbe incomprensibile.
                found.removeAll { $0.id == custom.id }
                found.append(custom)
            }
        }

        // Per nome, così l'elenco nelle Impostazioni non cambia ordine da un
        // avvio all'altro (il file system non promette nessun ordine).
        entries = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if entries.isEmpty {
            Log.error(
                "Nessuna mascotte trovata in \(Self.bundledFolder?.path ?? "nessuna cartella")",
                category: .mascot
            )
        } else {
            Log.info(
                "Mascotte disponibili: \(entries.map(\.id).joined(separator: ", "))",
                category: .mascot
            )
        }
    }

    /// La mascotte scelta, o la prima che c'è.
    ///
    /// Non lasciare mai l'app senza disegni è la parte importante: un
    /// identificativo salvato può riferirsi a una mascotte tolta da un
    /// aggiornamento, o a una cartella che l'utente ha spostato.
    func entry(withID id: String?) -> Entry? {
        if let id, let exact = entries.first(where: { $0.id == id }) { return exact }
        if id != nil, !entries.isEmpty {
            Log.info("Mascotte «\(id ?? "")» non trovata: uso «\(entries[0].id)»", category: .mascot)
        }
        return entries.first
    }

    /// Quella scelta dall'utente, se c'è.
    var customEntry: Entry? { entries.first { !$0.isBuiltIn } }

    private func load(from directory: URL, isBuiltIn: Bool) -> [Entry] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.compactMap { loadOne(folder: $0, isBuiltIn: isBuiltIn) }
    }

    private func loadOne(folder: URL, isBuiltIn: Bool) -> Entry? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        do {
            let sprites = try MascotSprites.load(from: folder)
            return Entry(
                id: sprites.manifest.id,
                name: sprites.manifest.name,
                author: sprites.manifest.author,
                folder: folder,
                isBuiltIn: isBuiltIn,
                sprites: sprites
            )
        } catch {
            // Una cartella rotta non deve impedire alle altre di caricarsi, ma
            // deve lasciare traccia: è l'unico modo che ha l'utente di capire
            // perché la mascotte che si è disegnato non compare.
            Log.error("Mascotte «\(folder.lastPathComponent)» scartata: \(error)", category: .mascot)
            return nil
        }
    }
}
