import Foundation
import Combine

/// Reads the status files written by the Claude Code hooks and exposes one
/// aggregated status per project path.
@MainActor
final class ClaudeStatusStore: ObservableObject {
    @Published private(set) var statusesByPath: [String: ClaudeProjectStatus] = [:]
    @Published private(set) var hooksInstalled = false

    /// A `working` record that stops being refreshed for this long is treated as
    /// unknown rather than trusted: the session probably died without firing
    /// `Stop` (crash, killed terminal, force quit).
    private let staleAfter: TimeInterval = 10 * 60

    /// Files older than this are junk from long-dead sessions and get deleted.
    private let purgeAfter: TimeInterval = 24 * 60 * 60

    private var watcher: DirectoryWatcher?
    private var staleTicker: Timer?
    private let settings: Settings
    private let notifier: WaitingInputNotifier

    /// Previous state per project, so we only notify on an actual transition.
    private var previousStates: [String: ClaudeActivity] = [:]

    /// Known VS Code project roots, used to fold a session started in a
    /// subdirectory onto the project it belongs to. The hook can only report a
    /// git root; for non-git projects this is what gets the grouping right.
    private var knownProjectPaths: [String] = []
    private var catalogLoadedAt: Date = .distantPast

    init(settings: Settings, notifier: WaitingInputNotifier) {
        self.settings = settings
        self.notifier = notifier
    }

    func start() {
        Paths.ensureStatusDirectory()
        refreshHookInstallationState()
        refreshCatalogIfStale()

        watcher = DirectoryWatcher(url: Paths.statusDirectory) { [weak self] in
            Task { @MainActor in self?.scan() }
        }
        watcher?.start()

        // FSEvents covers file changes; this ticker exists for the passage of
        // time alone — a `working` record going stale is not a file event.
        let ticker = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCatalogIfStale()
                self?.scan()
                self?.refreshHookInstallationState()
            }
        }
        ticker.tolerance = 5
        RunLoop.main.add(ticker, forMode: .common)
        staleTicker = ticker

        scan()
        Log.info("ClaudeStatusStore avviato su \(Paths.statusDirectory.path)", category: .status)
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        staleTicker?.invalidate()
        staleTicker = nil
    }

    // MARK: - Lookup

    /// Status for a VS Code project. Exact path first; otherwise the deepest
    /// project that contains the session's directory, since `claude` is often
    /// launched from a subfolder of the repository.
    func status(for project: VSCodeProject) -> ClaudeProjectStatus? {
        guard let path = project.path else { return nil }
        if let exact = statusesByPath[path] { return exact }

        return statusesByPath
            .filter { $0.key.hasPrefix(path + "/") }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    /// Projects currently waiting for the user, for the menu bar indicator.
    var waitingCount: Int {
        statusesByPath.values.filter { $0.state == .waitingInput }.count
    }

    // MARK: - Scanning

    private func scan() {
        let now = Date()
        var sessions: [ClaudeSessionStatus] = []
        var purged = 0

        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: Paths.statusDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            if !statusesByPath.isEmpty { statusesByPath = [:] }
            return
        }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = ClaudeSessionStatus(json: json)
            else { continue }

            if now.timeIntervalSince(session.updatedAt) > purgeAfter {
                try? fileManager.removeItem(at: file)
                purged += 1
                continue
            }

            sessions.append(session)
        }

        if purged > 0 {
            Log.debug("Rimossi \(purged) file di stato obsoleti (>24h)", category: .status)
        }

        let normalized = sessions.map { $0.movedToProjectRoot(among: knownProjectPaths) }
        let aggregated = Self.aggregate(normalized, now: now, staleAfter: staleAfter)
        guard aggregated != statusesByPath else { return }

        statusesByPath = aggregated
        notifyTransitions(aggregated)

        if aggregated.isEmpty {
            Log.debug("Nessuna sessione Claude Code attiva", category: .status)
        } else {
            let summary = aggregated
                .sorted { $0.key < $1.key }
                .map { path, status in
                    let name = (path as NSString).lastPathComponent
                    let badge = status.badge.map { " (\($0))" } ?? ""
                    return "\(name)=\(status.state.rawValue)\(badge)\(status.isStale ? " [stale]" : "")"
                }
                .joined(separator: ", ")
            Log.debug("Stato Claude Code: \(summary)", category: .status)
        }
    }

    /// Groups sessions by project and keeps the most urgent state per project.
    private static func aggregate(
        _ sessions: [ClaudeSessionStatus],
        now: Date,
        staleAfter: TimeInterval
    ) -> [String: ClaudeProjectStatus] {
        var byPath: [String: [ClaudeSessionStatus]] = [:]
        for session in sessions {
            byPath[session.projectPath, default: []].append(session)
        }

        var result: [String: ClaudeProjectStatus] = [:]
        for (path, group) in byPath {
            // Downgrade any record that claims to be busy but stopped reporting.
            let adjusted = group.map { session -> (ClaudeSessionStatus, ClaudeActivity, Bool) in
                let age = now.timeIntervalSince(session.updatedAt)
                let wentQuiet = age > staleAfter
                    && (session.state == .working || session.state == .waitingInput)
                return (session, wentQuiet ? .unknown : session.state, wentQuiet)
            }

            // Most urgent state wins; ties go to the most recently updated.
            guard let winner = adjusted.max(by: { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.updatedAt < rhs.0.updatedAt : lhs.1 < rhs.1
            }) else { continue }

            result[path] = ClaudeProjectStatus(
                projectPath: path,
                state: winner.1,
                detail: winner.0.detail,
                requestKind: winner.0.requestKind,
                updatedAt: group.map(\.updatedAt).max() ?? winner.0.updatedAt,
                sessionCount: group.count,
                isStale: winner.2
            )
        }
        return result
    }

    private func notifyTransitions(_ statuses: [String: ClaudeProjectStatus]) {
        for (path, status) in statuses {
            let previous = previousStates[path]
            previousStates[path] = status.state

            guard settings.notifyOnWaitingInput,
                  status.state == .waitingInput,
                  previous != .waitingInput
            else { continue }

            let name = (path as NSString).lastPathComponent
            notifier.notifyWaiting(projectName: name, badge: status.badge)
        }

        // Forget projects whose status files are gone, so a later re-appearance
        // counts as a fresh transition.
        for path in previousStates.keys where statuses[path] == nil {
            previousStates.removeValue(forKey: path)
        }
    }

    /// Reloaded rarely: the set of known workspaces only changes when a project
    /// is opened for the first time.
    private func refreshCatalogIfStale() {
        guard Date().timeIntervalSince(catalogLoadedAt) > 60 else { return }
        let catalog = WorkspaceCatalog.load(for: EditorApp.all)
        knownProjectPaths = catalog.entriesByName.values.map(\.path)
        catalogLoadedAt = Date()
    }

    // MARK: - Hook installation state

    /// Detects our hooks by the marker in their command, the same way the
    /// installer identifies its own entries.
    private func refreshHookInstallationState() {
        let installed = HookInstaller.areHooksInstalled()
        if installed != hooksInstalled {
            hooksInstalled = installed
            Log.info("Hook Claude Code \(installed ? "rilevati" : "assenti")", category: .status)
        }
    }
}
