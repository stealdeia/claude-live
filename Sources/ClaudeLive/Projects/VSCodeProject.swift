import Foundation

/// A project row in the panel: one open VS Code project.
struct VSCodeProject: Identifiable, Sendable, Equatable {
    /// The root name VS Code shows for the window.
    let name: String
    /// Full path, resolved from the workspace catalog. Nil when the name is not
    /// in the catalog — the row still works, but Claude Code status can't be
    /// matched to it.
    let path: String?
    /// How many windows have this project open.
    let windowCount: Int
    let bundleID: String
    /// When the workspace was last opened, used for ordering.
    let lastUsed: Date?

    /// Path is the stable identity when we have it, so SwiftUI keeps row state
    /// across refreshes.
    var id: String { path ?? "name:\(name)" }

    /// `~`-shortened path for the row tooltip.
    var displayPath: String? {
        guard let path else { return nil }
        let home = Paths.home.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
