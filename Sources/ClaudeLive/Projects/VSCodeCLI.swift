import AppKit

/// Talks to a running VS Code through its bundled `code` CLI.
///
/// Why not the Accessibility API? VS Code uses a custom (non-native) title bar,
/// so every window reports `AXTitle == "Code"` — the project name simply is not
/// in the AX tree. `code --status` gets it straight from VS Code's main process:
///
/// ```text
/// Workspace Stats:
/// |  Window (Costruire app macOS Sipp… — progetto-alfa)
/// |  Window (Claude Live: macOS menu … — hub-claude)
/// |  Window (Fix scrolling, notificat… — progetto-beta)
/// ```
///
/// Note what is inside the parentheses: the **window title**, not the folder
/// name. VS Code's default title is
/// `${activeEditorShort}${separator}${rootName}`, so it only *looks* like a
/// plain project name while no editor or terminal tab is active — which is
/// exactly how this was first (mis)read. With a Claude Code session running in
/// the integrated terminal the title becomes "<tab> — <project>", and VS Code
/// truncates the leading part itself. `resolveProject` is what turns it back
/// into a project.
///
/// Two costs, both of which shape how often callers may run this:
///   * the call takes ~1.6s, because VS Code also computes workspace file stats;
///   * the CLI registers a **second VS Code instance** with LaunchServices, so an
///     icon flashes in the Dock for the duration.
/// So refreshes are event-driven, never on a fast timer. In exchange the whole
/// feature needs **no macOS permission at all**.
struct VSCodeCLI: Sendable {
    struct OpenWindow: Sendable {
        /// The root name VS Code displays for the window.
        let name: String
        let bundleID: String
    }

    /// Running VS Code-family apps, paired with their CLI executable.
    static func runningEditors() -> [(editor: EditorApp, cli: URL)] {
        var found: [(EditorApp, URL)] = []
        for editor in EditorApp.all {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: editor.bundleID)
            // Derive the CLI from the running bundle so a non-standard install
            // location still works.
            guard let bundleURL = apps.compactMap(\.bundleURL).first else { continue }
            let cli = bundleURL.appendingPathComponent("Contents/Resources/app/bin/code")
            guard FileManager.default.isExecutableFile(atPath: cli.path) else {
                Log.error("CLI code non eseguibile: \(cli.path)", category: .projects)
                continue
            }
            found.append((editor, cli))
        }
        return found
    }

    /// Queries every running editor for its open windows.
    /// Blocking — call from a background queue.
    ///
    /// `onSpawn` reports the pid of each CLI process we start, so the caller can
    /// tell our own app-lifecycle noise apart from the user really launching or
    /// quitting VS Code.
    static func openWindows(onSpawn: @escaping (pid_t) -> Void = { _ in }) -> [OpenWindow] {
        var windows: [OpenWindow] = []
        for (editor, cli) in runningEditors() {
            guard let output = run(cli, arguments: ["--status"], timeout: 15, onSpawn: onSpawn) else { continue }
            let titles = parseWindowTitles(from: output)
            windows.append(contentsOf: titles.map { OpenWindow(name: $0, bundleID: editor.bundleID) })
        }
        return windows
    }

    /// Extracts the window titles from `code --status` output.
    /// Lines look like `|  Window (file.swift — hub-claude)`; empty windows
    /// appear as `|  Window ()` and are skipped.
    static func parseWindowTitles(from output: String) -> [String] {
        var names: [String] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { continue }

            let body = trimmed.drop(while: { $0 == "|" || $0 == " " })
            guard body.hasPrefix("Window ("), body.hasSuffix(")") else { continue }

            let name = String(body.dropFirst("Window (".count).dropLast())
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.append(name) }
        }
        return names
    }

    /// Turns a window title into the project it belongs to.
    ///
    /// Rather than trusting a position in the title — `window.title` is
    /// user-configurable, and the format has already changed under us once — this
    /// looks for the component that matches a workspace VS Code already knows
    /// about. That also yields the full path, which is what makes the row
    /// clickable and lets Claude Code's hooks be matched to it.
    static func resolveProject(
        fromTitle title: String,
        catalog: WorkspaceCatalog
    ) -> (name: String, path: String?) {
        let components = titleComponents(of: title)

        // Scan from the end: `rootName` sits near the end of the default format,
        // and an early component could coincidentally match a project name.
        for component in components.reversed() {
            if let entry = catalog.entriesByName[component] {
                return (entry.name, entry.path)
            }
        }

        // Nothing known matched: the last component is `rootName` under the
        // default format. No path, so the row stays visible but not clickable.
        let fallback = components.last ?? title.trimmingCharacters(in: .whitespaces)
        return (fallback, catalog.entriesByName[fallback]?.path)
    }

    /// Splits a window title and strips decorations: the unsaved-changes bullet,
    /// the app name, dev-host prefixes, and empty pieces from an unset profile.
    private static func titleComponents(of title: String) -> [String] {
        var working = title.trimmingCharacters(in: .whitespaces)

        for prefix in ["● ", "◍ ", "[Extension Development Host] "] {
            if working.hasPrefix(prefix) {
                working = String(working.dropFirst(prefix.count))
            }
        }

        // VS Code's default separator is an em dash; forks and custom configs use
        // an en dash or a hyphen.
        var pieces: [String] = [working]
        for separator in [" — ", " – ", " - "] {
            if working.contains(separator) {
                pieces = working.components(separatedBy: separator)
                break
            }
        }

        let noise = Set(EditorApp.all.flatMap(\.titleNoise))
        return pieces
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !noise.contains($0) }
    }

    /// Focuses the window that has `path` open.
    ///
    /// Two steps are needed: `code <path>` selects the right window inside VS
    /// Code but does **not** bring the app forward (verified — the frontmost app
    /// stayed unchanged), so we activate it ourselves afterwards.
    static func focus(
        path: String,
        bundleID: String,
        onSpawn: @escaping (pid_t) -> Void = { _ in }
    ) {
        guard let (_, cli) = runningEditors().first(where: { $0.editor.bundleID == bundleID })
            ?? runningEditors().first else {
            Log.error("Nessun editor in esecuzione per portare in primo piano \(path)", category: .projects)
            return
        }

        _ = run(cli, arguments: [path], timeout: 10, onSpawn: onSpawn)

        NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first?
            .activate()

        Log.debug("Focus richiesto su \(path)", category: .projects)
    }

    // MARK: - Process plumbing

    /// Runs the CLI and returns stdout, or nil on failure/timeout.
    private static func run(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        onSpawn: @escaping (pid_t) -> Void
    ) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        // Keep stderr out of the parsed output but don't let it fill a pipe.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            onSpawn(process.processIdentifier)
        } catch {
            Log.error("Avvio di \(executable.lastPathComponent) fallito: \(error.localizedDescription)", category: .projects)
            return nil
        }

        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        // Guard against a wedged CLI holding the queue forever.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            Log.error("\(executable.lastPathComponent) \(arguments.first ?? "") in timeout", category: .projects)
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}
