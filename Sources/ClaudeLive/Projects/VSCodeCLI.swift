import AppKit

/// Talks to a running VS Code through its bundled `code` CLI.
///
/// Why not the Accessibility API? VS Code uses a custom (non-native) title bar,
/// so every window reports `AXTitle == "Code"` — the project name simply is not
/// in the AX tree. `code --status` gets it straight from VS Code's main process:
///
/// ```text
/// Workspace Stats:
/// |  Window (progetto-alfa)
/// |  Window (hub-claude)
/// |  Window (progetto-beta)
/// ```
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
            let names = parseWindowNames(from: output)
            windows.append(contentsOf: names.map { OpenWindow(name: $0, bundleID: editor.bundleID) })
        }
        return windows
    }

    /// Extracts the root names from `code --status` output.
    /// Lines look like `|  Window (hub-claude)`; empty windows appear as
    /// `|  Window ()` and are skipped.
    static func parseWindowNames(from output: String) -> [String] {
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
