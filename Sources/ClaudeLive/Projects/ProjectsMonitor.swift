import AppKit
import Combine

/// Keeps the list of open VS Code projects fresh.
///
/// Refreshing means running `code --status`, which has a visible side effect:
/// the CLI briefly registers a **second VS Code instance** with LaunchServices,
/// so an icon flashes in the Dock. That makes frequency a UX problem, not just a
/// performance one — so this class refreshes only on signals that mean a project
/// list actually changed, and never runs the CLI on a fast timer.
///
/// The one thing that *does* run on a fast timer is a silent poll of VS Code's
/// **window id set** via `CGWindowListCopyWindowInfo`: no subprocess, no Dock
/// flash, no macOS permission (only window titles are permission-gated, not
/// ids). It exists because the other signals all miss one case — re-opening
/// a project VS Code already knows, from an already-running VS Code: no app
/// launch event fires and no new workspaceStorage directory appears.
///
/// It also has to avoid a feedback loop: our own CLI spawn fires
/// `didLaunchApplicationNotification` / `didTerminateApplicationNotification`
/// for VS Code's bundle id. Treating those as change signals made the app
/// refresh forever, spawning a CLI every couple of seconds.
///
/// The defence is a time window around each of our calls. Pid matching alone
/// would not do: the pid we get back is the `code` shell script's, while the
/// process that registers with LaunchServices is its Electron child, with a
/// different pid. The pid set is kept as a cheap extra filter, not the mechanism.
@MainActor
final class ProjectsMonitor: ObservableObject {
    @Published private(set) var projects: [VSCodeProject] = []
    @Published private(set) var isEditorRunning = false
    @Published private(set) var isRefreshing = false
    /// Window names VS Code reported that aren't in the workspace catalog.
    @Published private(set) var unresolvedNames: [String] = []

    /// Floor between two refreshes.
    private let minimumInterval: TimeInterval = 4
    /// App-lifecycle events within this window of one of our own CLI spawns are
    /// assumed to be caused by it.
    private let selfNoiseWindow: TimeInterval = 6

    private let editors = EditorApp.all
    private let settings: Settings
    private var catalog = WorkspaceCatalog()
    private var catalogLoadedAt: Date = .distantPast

    private var timer: Timer?
    private var intervalObserver: AnyCancellable?
    private var observers: [Any] = []
    private var workspaceWatchers: [DirectoryWatcher] = []

    /// Window poll: the only timer allowed to be fast, because a tick costs no
    /// subprocess. Tracks window *ids*, not a count: VS Code keeps phantom
    /// layer-0 helper windows (tab-bar strips, a 500×500 buffer — observed
    /// live), and a set of ids survives one phantom appearing while a real
    /// window closes, where a bare count would cancel out.
    private var windowCountTimer: Timer?
    /// Baseline we last acted on. nil until the first tick.
    private var lastWindowIDs: Set<CGWindowID>?
    /// A changed set is acted on only after two identical consecutive ticks,
    /// so transient popups don't each cost a CLI spawn.
    private var pendingWindowIDs: Set<CGWindowID>?

    private var lastRefreshAt: Date = .distantPast
    private var refreshing = false
    private var pendingRefresh = false

    /// Names of the workspaceStorage directories seen last time. VS Code writes
    /// inside those directories while you work, so a file event there does not by
    /// itself mean the project list changed — comparing the *set* does.
    private var knownWorkspaceDirs: Set<String> = []

    /// How long an unchanged workspace set suppresses a refresh. Re-opening a
    /// project VS Code already knows creates no new directory, so this bounds how
    /// stale the list can get without making the CLI flash constantly.
    private let unchangedSetGrace: TimeInterval = 15 * 60

    /// Set while a just-opened workspace may still be settling. Right after its
    /// workspaceStorage directory appears (or right after VS Code launches),
    /// `code --status` can report the window as empty and workspace.json may not
    /// be written yet, so a single refresh at that moment shows nothing — the
    /// list then stays stale until a manual refresh. See armSettleRefreshes.
    private var settleUntil: Date = .distantPast
    /// Invalidates the settle follow-ups of a previous trigger.
    private var settleGeneration = 0

    /// Set while one of our CLI calls may still be generating app events.
    private var suppressAppEventsUntil: Date = .distantPast
    /// Pids we spawned directly. Only a partial filter — see the type comment.
    private var ownSpawnedPids: Set<pid_t> = []

    private let workQueue = DispatchQueue(label: "it.aldeialab.ClaudeLive.vscode", qos: .utility)

    init(settings: Settings) {
        self.settings = settings
    }

    func start() {
        Log.info("ProjectsMonitor avviato (via code --status, nessun permesso richiesto)", category: .projects)

        rearmTimer()
        intervalObserver = settings.$projectsRefreshMinutes
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.rearmTimer() }
            }

        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in self?.handleAppEvent(note) }
            })
        }

        // Opening a folder creates a workspaceStorage directory, which is the
        // cheapest permission-free signal that the project list changed. But VS
        // Code also writes UI state inside those directories as you work, so the
        // events have to be filtered — see handleWorkspaceStorageEvent.
        _ = workspaceDirsChanged()
        for editor in editors {
            let watcher = DirectoryWatcher(url: editor.workspaceStorageURL, latency: 0.5) { [weak self] in
                Task { @MainActor in self?.handleWorkspaceStorageEvent() }
            }
            watcher.start()
            workspaceWatchers.append(watcher)
        }

        let windowTimer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkWindowCount() }
        }
        windowTimer.tolerance = 1
        RunLoop.main.add(windowTimer, forMode: .common)
        windowCountTimer = windowTimer

        refresh(reason: "avvio")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        windowCountTimer?.invalidate()
        windowCountTimer = nil
        settleGeneration += 1
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        workspaceWatchers.forEach { $0.stop() }
        workspaceWatchers.removeAll()
    }

    /// Off by default; only armed if the user opts into periodic refresh.
    private func rearmTimer() {
        timer?.invalidate()
        timer = nil

        let minutes = settings.projectsRefreshMinutes
        guard minutes > 0 else {
            Log.debug("Refresh periodico progetti disattivato", category: .projects)
            return
        }

        let timer = Timer(timeInterval: minutes * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(reason: "timer") }
        }
        timer.tolerance = minutes * 6
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.debug("Refresh periodico progetti ogni \(Int(minutes)) min", category: .projects)
    }

    /// VS Code launching or quitting for real is worth a refresh; our own CLI
    /// spawns are not.
    private func handleAppEvent(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              EditorApp.all.contains(where: { $0.bundleID == bundleID })
        else { return }

        let pid = app.processIdentifier
        if ownSpawnedPids.contains(pid) {
            ownSpawnedPids.remove(pid)
            return
        }
        if Date() < suppressAppEventsUntil {
            Log.debug("Evento app ignorato (probabile spawn nostro)", category: .projects)
            return
        }

        // Cheap: no subprocess involved.
        updateEditorRunningFlag()
        if note.name == NSWorkspace.didLaunchApplicationNotification {
            armSettleRefreshes(reason: "avvio VS Code")
        }
        refresh(reason: "avvio/chiusura VS Code")
    }

    /// A workspace that has just been opened needs more than the one immediate
    /// refresh: in the field that refresh ran while `code --status` still
    /// reported the new window as `Window ()` and before workspace.json existed,
    /// so the project never appeared and every later event was suppressed as
    /// "set unchanged". The follow-ups below catch the settled state; they are
    /// few and far apart because every one costs a Dock-icon flash.
    private func armSettleRefreshes(reason: String, delays: [TimeInterval] = [10, 30, 75]) {
        settleUntil = Date().addingTimeInterval((delays.max() ?? 0) + 15)
        settleGeneration += 1
        let generation = settleGeneration
        for delay in delays {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.settleGeneration == generation else { return }
                self.refresh(reason: "\(reason), assestamento +\(Int(delay))s")
            }
        }
    }

    /// A file event under workspaceStorage only warrants the (visible) cost of
    /// running the CLI when the set of workspaces actually changed.
    ///
    /// Without this filter the app spawned `code --status` every few seconds while
    /// VS Code saved its state, and each spawn flashes a second VS Code icon in
    /// the Dock — the symptom reported as "VS Code keeps opening and closing".
    private func handleWorkspaceStorageEvent() {
        if workspaceDirsChanged() {
            armSettleRefreshes(reason: "nuovo workspace")
            refresh(reason: "nuovo workspace")
            return
        }
        guard Date().timeIntervalSince(lastRefreshAt) > unchangedSetGrace else {
            Log.debug("Evento workspaceStorage ignorato: insieme invariato", category: .projects)
            return
        }
        refresh(reason: "workspaceStorage (controllo periodico)")
    }

    /// Compares the set of workspaceStorage directory names with the previous one.
    /// Cheap: one directory listing, no subprocess.
    private func workspaceDirsChanged() -> Bool {
        var current: Set<String> = []
        for editor in editors {
            let entries = (try? FileManager.default.contentsOfDirectory(
                atPath: editor.workspaceStorageURL.path
            )) ?? []
            current.formUnion(entries.map { "\(editor.supportDirName)/\($0)" })
        }
        defer { knownWorkspaceDirs = current }
        // First call only records the baseline.
        guard !knownWorkspaceDirs.isEmpty else { return false }
        return current != knownWorkspaceDirs
    }

    /// Compares the current set of VS Code window ids with the last tick's.
    ///
    /// A stable change means a window opened or closed — the one signal the
    /// app-event and workspaceStorage paths both miss when a known project is
    /// re-opened from a running VS Code. Ticks that see no change cost nothing
    /// visible.
    private func checkWindowCount() {
        let pids = Set(editors.flatMap { editor in
            NSRunningApplication.runningApplications(withBundleIdentifier: editor.bundleID)
                .map(\.processIdentifier)
        })
        let ids = pids.isEmpty ? [] : Self.editorWindowIDs(ownedBy: pids)

        // First tick only records the baseline; startup already refreshed.
        guard let last = lastWindowIDs else {
            lastWindowIDs = ids
            return
        }
        guard ids != last else {
            pendingWindowIDs = nil
            return
        }
        // A new set has to survive one more tick before it costs a CLI spawn.
        guard ids == pendingWindowIDs else {
            pendingWindowIDs = ids
            return
        }

        pendingWindowIDs = nil
        lastWindowIDs = ids
        let opened = ids.subtracting(last).count
        let closed = last.subtracting(ids).count
        Log.debug("Finestre VS Code: \(last.count) → \(ids.count) (+\(opened)/−\(closed))", category: .projects)

        if opened > 0 {
            // A freshly opened window may briefly report an empty title to
            // `code --status`, so give it one settle follow-up — but only one:
            // this is a known project, its workspace.json already exists.
            armSettleRefreshes(reason: "nuova finestra", delays: [10])
            refresh(reason: "nuova finestra")
        } else {
            refresh(reason: "finestra chiusa")
        }
    }

    /// Ids of VS Code's plausibly-real windows across all Spaces, minimized
    /// included (`kCGWindowIsOnscreen` is deliberately not consulted: it drops
    /// on minimize and on Space switches). Needs no permission — only window
    /// *titles* are gated behind Screen Recording, and we never read those.
    nonisolated private static func editorWindowIDs(ownedBy pids: Set<pid_t>) -> Set<CGWindowID> {
        guard let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var ids: Set<CGWindowID> = []
        for window in info {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pids.contains(pid),
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  // Electron keeps phantom helper windows at layer 0 (tab-bar
                  // strips ~30 px tall, a 500×500 buffer). The height cut drops
                  // the strips; the persistent 500×500 one is harmless because
                  // only *changes* of the id set trigger anything.
                  (bounds["Width"] ?? 0) > 200, (bounds["Height"] ?? 0) > 150
            else { continue }
            ids.insert(number)
        }
        return ids
    }

    private func updateEditorRunningFlag() {
        let running = editors.contains { editor in
            !NSRunningApplication.runningApplications(withBundleIdentifier: editor.bundleID).isEmpty
        }
        if running != isEditorRunning { isEditorRunning = running }
    }

    // MARK: - Refresh

    func refresh(reason: String) {
        updateEditorRunningFlag()

        guard isEditorRunning else {
            if !projects.isEmpty { projects = [] }
            return
        }

        // Coalesce: remember that another refresh is wanted and run it once the
        // current one finishes, instead of piling up subprocesses.
        if refreshing {
            pendingRefresh = true
            return
        }
        let sinceLast = Date().timeIntervalSince(lastRefreshAt)
        if sinceLast < minimumInterval {
            guard !pendingRefresh else { return }
            pendingRefresh = true
            let delay = minimumInterval - sinceLast
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.pendingRefresh else { return }
                self.pendingRefresh = false
                self.refresh(reason: "differito")
            }
            return
        }

        refreshing = true
        pendingRefresh = false
        lastRefreshAt = Date()
        isRefreshing = true
        // Cover the whole call plus the CLI process's own teardown events.
        suppressAppEventsUntil = Date().addingTimeInterval(selfNoiseWindow)
        Log.debug("Refresh progetti (\(reason))", category: .projects)

        refreshCatalogIfStale()
        let catalog = self.catalog

        workQueue.async { [weak self] in
            let result = VSCodeCLI.openWindows { pid in
                Task { @MainActor in self?.ownSpawnedPids.insert(pid) }
            }
            Task { @MainActor in
                guard let self else { return }
                self.apply(windows: result, catalog: catalog)
                self.refreshing = false
                self.isRefreshing = false
                self.suppressAppEventsUntil = Date().addingTimeInterval(self.selfNoiseWindow)
                if self.pendingRefresh {
                    self.pendingRefresh = false
                    self.refresh(reason: "accodato")
                }
            }
        }
    }

    private func apply(windows: [VSCodeCLI.OpenWindow], catalog: WorkspaceCatalog) {
        // `window.name` is a window *title*; resolve it to a project first, then
        // collapse windows that turn out to belong to the same one.
        var order: [String] = []
        var counts: [String: Int] = [:]
        var bundles: [String: String] = [:]
        var names: [String: String] = [:]
        var paths: [String: String?] = [:]

        let noiseNames = Set(EditorApp.all.flatMap(\.titleNoise))

        for window in windows {
            let resolved = VSCodeCLI.resolveProject(fromTitle: window.name, catalog: catalog)
            // A window still loading titles itself with the bare app name; that
            // is not a project, just a dead unclickable row.
            if resolved.path == nil, noiseNames.contains(resolved.name) { continue }
            let key = resolved.path ?? "name:\(resolved.name)"
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
            bundles[key] = window.bundleID
            names[key] = resolved.name
            paths[key] = resolved.path
        }

        let resolved = order.map { key -> VSCodeProject in
            let name = names[key] ?? key
            let path = paths[key] ?? nil
            return VSCodeProject(
                name: name,
                path: path,
                windowCount: counts[key] ?? 1,
                bundleID: bundles[key] ?? EditorApp.vsCode.bundleID,
                lastUsed: path.flatMap { p in catalog.entriesByName.values.first { $0.path == p }?.lastUsed }
            )
        }

        // Most recently opened first; unknown names keep VS Code's own order at
        // the end.
        let sorted = resolved.sorted { lhs, rhs in
            switch (lhs.lastUsed, rhs.lastUsed) {
            case let (l?, r?): return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.name < rhs.name
            }
        }

        let missing = resolved.filter { $0.path == nil }.map(\.name)
        if missing != unresolvedNames { unresolvedNames = missing }
        if !missing.isEmpty {
            Log.debug("Nomi senza path nel catalogo: \(missing.joined(separator: ", "))", category: .projects)
        }

        guard sorted != projects else { return }
        projects = sorted
        Log.debug("Progetti aperti: \(sorted.map(\.name).joined(separator: ", "))", category: .projects)
    }

    /// The catalog only changes when a workspace is opened for the first time;
    /// re-reading every entry on each refresh would be wasteful.
    private func refreshCatalogIfStale() {
        // While a workspace is settling its workspace.json can appear at any
        // moment, and the usual cache would keep resolving against a catalog
        // that predates it.
        let maxAge: TimeInterval = Date() < settleUntil ? 5 : 30
        guard Date().timeIntervalSince(catalogLoadedAt) > maxAge else { return }
        catalog = WorkspaceCatalog.load(for: editors)
        catalogLoadedAt = Date()
    }

    // MARK: - Actions

    /// Focuses by path. Used by notifications and by the pending-request rows,
    /// where the project may not be in the current list — a window closed, or the
    /// list is a few seconds stale. Asking VS Code directly still does the right
    /// thing, so this never silently does nothing.
    func focus(path: String) {
        if let project = projects.first(where: { $0.path == path }) {
            focus(project)
            return
        }
        suppressAppEventsUntil = Date().addingTimeInterval(selfNoiseWindow)
        workQueue.async { [weak self] in
            VSCodeCLI.focus(path: path, bundleID: EditorApp.vsCode.bundleID) { pid in
                Task { @MainActor in self?.ownSpawnedPids.insert(pid) }
            }
        }
        Log.debug("Focus per path richiesto: \(path)", category: .projects)
    }

    func focus(_ project: VSCodeProject) {
        guard let path = project.path else {
            Log.error("Impossibile portare in primo piano «\(project.name)»: path sconosciuto", category: .projects)
            return
        }
        let bundleID = project.bundleID
        suppressAppEventsUntil = Date().addingTimeInterval(selfNoiseWindow)

        // Blocking (~1s): keep it off the main thread so the panel stays live.
        workQueue.async { [weak self] in
            VSCodeCLI.focus(path: path, bundleID: bundleID) { pid in
                Task { @MainActor in self?.ownSpawnedPids.insert(pid) }
            }
        }
    }
}
