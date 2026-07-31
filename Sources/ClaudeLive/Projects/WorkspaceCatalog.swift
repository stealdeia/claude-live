import Foundation

/// Maps a project *name* to its full path on disk.
///
/// Window titles only ever contain the folder name, but Phase 3 needs to match
/// Claude Code hooks (which report a `cwd`) to the right row — so we need paths.
/// VS Code conveniently keeps one directory per known workspace at
/// `…/User/workspaceStorage/<hash>/workspace.json`:
///
/// ```json
/// { "folder": "file:///Users/me/Repository%20Github/hub-claude" }
/// ```
///
/// This doubles as a dictionary of *known project names*, which is what makes
/// title parsing robust: instead of guessing which component of
/// "Credentials.swift — hub-claude" is the project, we look for the component
/// that is a name we already know.
struct WorkspaceCatalog {
    struct Entry {
        let name: String
        let path: String
        /// Directory mtime — used to prefer the most recently opened duplicate.
        let lastUsed: Date
    }

    private(set) var entriesByName: [String: Entry] = [:]

    var knownNames: Set<String> { Set(entriesByName.keys) }

    func path(forName name: String) -> String? {
        entriesByName[name]?.path
    }

    static func load(for editors: [EditorApp]) -> WorkspaceCatalog {
        var catalog = WorkspaceCatalog()
        let fileManager = FileManager.default

        for editor in editors {
            let root = editor.workspaceStorageURL
            guard let hashDirs = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for dir in hashDirs {
                let file = dir.appendingPathComponent("workspace.json")
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                guard let entry = Self.entry(from: json, directory: dir) else { continue }

                // Two windows can know the same project name from different
                // paths; the most recently touched one wins.
                if let existing = catalog.entriesByName[entry.name],
                   existing.lastUsed >= entry.lastUsed {
                    continue
                }
                catalog.entriesByName[entry.name] = entry
            }
        }

        Log.debug("Catalogo workspace: \(catalog.entriesByName.count) progetti noti", category: .projects)
        return catalog
    }

    private static func entry(from json: [String: Any], directory: URL) -> Entry? {
        let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast

        // A plain folder workspace.
        if let folder = json["folder"] as? String,
           let url = URL(string: folder),
           url.isFileURL {
            let path = url.standardizedFileURL.path
            return Entry(name: (path as NSString).lastPathComponent, path: path, lastUsed: modified)
        }

        // A multi-root .code-workspace file: the displayed root name is the file
        // name without its extension.
        if let workspace = json["workspace"] as? String,
           let url = URL(string: workspace),
           url.isFileURL {
            let path = url.standardizedFileURL.path
            var name = (path as NSString).lastPathComponent
            if name.hasSuffix(".code-workspace") {
                name = String(name.dropLast(".code-workspace".count))
            }
            return Entry(name: name, path: path, lastUsed: modified)
        }

        return nil
    }
}
