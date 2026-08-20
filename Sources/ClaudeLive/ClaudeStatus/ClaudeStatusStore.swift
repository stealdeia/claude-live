import Foundation
import Combine
import ClaudeLiveKit

/// Reads the status files written by the Claude Code hooks and exposes one
/// aggregated status per project path.
@MainActor
final class ClaudeStatusStore: ObservableObject {
    @Published private(set) var statusesByPath: [String: ClaudeProjectStatus] = [:]
    @Published private(set) var hooksInstalled = false

    /// Sessions currently waiting on the user, newest first.
    ///
    /// Kept per-session rather than folded into `statusesByPath`: each pending
    /// permission request has its own identity, and answering one must not be
    /// confused with answering another in the same project.
    @Published private(set) var waitingSessions: [ClaudeSessionStatus] = []

    /// Every live session, grouped by project and sorted most urgent first.
    ///
    /// This is what the panel shows as "chats": one Claude Code session is one
    /// conversation, and a project routinely has several — one per terminal, in
    /// one or more editor windows. The aggregate in `statusesByPath` deliberately
    /// collapses them to the single most urgent state, which is the right summary
    /// and the wrong answer to "what is each of them doing".
    @Published private(set) var sessionsByPath: [String: [ClaudeSessionStatus]] = [:]

    /// A `working` record that stops being refreshed for this long is treated as
    /// unknown rather than trusted: the session probably died without firing
    /// `Stop` (crash, killed terminal, force quit).
    private let staleAfter: TimeInterval = 10 * 60

    /// Files older than this are junk from long-dead sessions and get deleted.
    private let purgeAfter: TimeInterval = 24 * 60 * 60

    private var watcher: DirectoryWatcher?
    private var staleTicker: Timer?
    private var heartbeatTicker: Timer?
    private let settings: Settings
    private let notifier: ClaudeAlertNotifier

    /// Unacknowledged events, one per project at most: the newest replaces the
    /// previous, because a project has one row to click and one thing to say.
    @Published private(set) var alerts: [String: ClaudeAlert] = [:]

    /// The alert the notch strip should show: the most serious, then the newest.
    var topAlert: ClaudeAlert? {
        alerts.values.max { ClaudeAlert.moreUrgent($1, $0) }
    }

    /// Previous state per project, so we only act on an actual transition.
    private var previousStates: [String: ClaudeActivity] = [:]

    /// Known VS Code project roots, used to fold a session started in a
    /// subdirectory onto the project it belongs to. The hook can only report a
    /// git root; for non-git projects this is what gets the grouping right.
    private var knownProjectPaths: [String] = []
    private var catalogLoadedAt: Date = .distantPast

    private var cancellables: Set<AnyCancellable> = []

    init(settings: Settings, notifier: ClaudeAlertNotifier) {
        self.settings = settings
        self.notifier = notifier
    }

    func start() {
        Paths.ensureStatusDirectory()
        refreshHookInstallationState()
        refreshCatalogIfStale()
        writeHubConfig()
        touchHeartbeat()

        // The hook only blocks a permission request while this file is fresh, so
        // if the app is not running Claude Code behaves exactly as it always did.
        let heartbeat = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.touchHeartbeat() }
        }
        heartbeat.tolerance = 5
        RunLoop.main.add(heartbeat, forMode: .common)
        heartbeatTicker = heartbeat

        // The hook reads the wait from disk, so a change takes effect without
        // reinstalling anything.
        settings.$decisionWaitSeconds
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.writeHubConfig() }
            }
            .store(in: &cancellables)

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
        heartbeatTicker?.invalidate()
        heartbeatTicker = nil
        // Removed rather than left stale: the hook should stop waiting for an app
        // that has quit, immediately rather than after the heartbeat ages out.
        try? FileManager.default.removeItem(at: Paths.heartbeatFile)
    }

    // MARK: - Bridge with the hook

    /// Writes pid and timestamp, not just a touch.
    ///
    /// The hook checks the pid is alive before it agrees to wait for an answer. A
    /// crash or a force-quit never runs `stop()`, so a file that only carried a
    /// timestamp would keep every permission request stalling with nobody there
    /// to answer it.
    private func touchHeartbeat() {
        try? FileManager.default.createDirectory(at: Paths.hubDirectory, withIntermediateDirectories: true)
        let beat: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "at": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: beat) else { return }
        try? data.write(to: Paths.heartbeatFile, options: .atomic)
    }

    /// Set while the user is away and the phone can answer instead, so the hook
    /// waits long enough for a human to notice a notification. See `RemoteWaitPolicy`.
    var awayWaitSeconds: Double? {
        didSet {
            guard awayWaitSeconds != oldValue else { return }
            writeHubConfig()
        }
    }

    /// The wait the hook should use right now.
    ///
    /// Measured on 2026-08-19: a notification reaches the phone in 1.2s, but the
    /// time for a person to notice and answer was 11s *while expecting it* — and
    /// unbounded when not. So a single number cannot be right. At the Mac, a long
    /// wait is pure obstruction; away from it, a session frozen while nobody is
    /// watching costs nothing, and the wait is the only thing that makes answering
    /// from the phone possible at all.
    private var effectiveWaitSeconds: Double {
        awayWaitSeconds ?? settings.decisionWaitSeconds
    }

    /// Tools worth stopping for while away. Read-only ones are absent on purpose:
    /// they cannot change anything, and asking about them would turn one task
    /// into twenty questions on a phone screen.
    static let gatedTools = ["Bash", "Write", "Edit", "NotebookEdit"]

    private func writeHubConfig() {
        try? FileManager.default.createDirectory(at: Paths.hubDirectory, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "decision_wait_seconds": effectiveWaitSeconds,
            // The hook holds a tool call only while this is true. It is the same
            // condition that lengthens the wait: away from the Mac, with a phone
            // able to answer.
            "away": awayWaitSeconds != nil,
            "gated_tools": Self.gatedTools,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) else { return }
        try? data.write(to: Paths.hubConfigFile, options: .atomic)
        Log.debug(
            "Attesa risposta permessi: \(Int(effectiveWaitSeconds))s\(awayWaitSeconds == nil ? "" : " (sei via)")",
            category: .status
        )
    }

    /// Answers a permission request the hook is blocked on.
    ///
    /// The answer is a file the hook is polling for; `remember` makes the hook add
    /// this exact request to its allowlist, so an identical one is allowed without
    /// asking again. "Exact" means the same project, tool and tool input — never
    /// "all Bash in this project", which would be far broader than what was agreed.
    func decide(_ session: ClaudeSessionStatus, allow: Bool, remember: Bool = false) {
        guard let requestID = session.requestID, !requestID.isEmpty else { return }
        try? FileManager.default.createDirectory(at: Paths.decisionsDirectory, withIntermediateDirectories: true)

        let answer: [String: Any] = [
            "behavior": allow ? "allow" : "deny",
            "remember": remember,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: answer) else { return }
        let url = Paths.decisionsDirectory.appendingPathComponent("\(requestID).json")
        do {
            try data.write(to: url, options: .atomic)
            Log.info(
                "Risposta a «\(session.projectName)»: \(allow ? "consentito" : "negato")\(remember ? " (sempre)" : "")",
                category: .status
            )
        } catch {
            Log.error("Risposta non scritta: \(error.localizedDescription)", category: .status)
            return
        }

        // Drop it from the list at once: the hook will rewrite the status file a
        // moment later, and leaving a dead button on screen invites a second click.
        waitingSessions.removeAll { $0.id == session.id }
    }

    // MARK: - Lookup

    /// Status for a VS Code project: the aggregate of exactly the sessions
    /// `sessions(for:)` lists.
    ///
    /// Derived from that list rather than looked up in `statusesByPath` so the two
    /// can never disagree. They could before: a project with both a session on its
    /// root and one started in a subdirectory got its summary from the root group
    /// alone, so a subdirectory session waiting for an answer was counted in the
    /// chat list and missing from the dot — the one case where being wrong costs
    /// something.
    func status(for project: VSCodeProject) -> ClaudeProjectStatus? {
        guard let path = project.path else { return nil }
        let sessions = self.sessions(for: project)
        guard let winner = sessions.first else { return nil }
        return ClaudeProjectStatus(
            projectPath: path,
            state: winner.state,
            detail: winner.detail,
            requestKind: winner.requestKind,
            updatedAt: sessions.map(\.updatedAt).max() ?? winner.updatedAt,
            sessionCount: sessions.count,
            isStale: winner.isStale
        )
    }

    /// Every session of a VS Code project, most urgent first.
    ///
    /// Same lookup as `status(for:)`, but it collects *all* the matching paths:
    /// two chats in the same project may have been started from different
    /// subdirectories, and each one is a separate row.
    func sessions(for project: VSCodeProject) -> [ClaudeSessionStatus] {
        guard let path = project.path else { return [] }
        var found = sessionsByPath[path] ?? []
        for (key, sessions) in sessionsByPath where key.hasPrefix(path + "/") {
            found.append(contentsOf: sessions)
        }
        return Self.sortedByUrgency(found)
    }

    /// Projects currently waiting for the user, for the menu bar indicator.
    var waitingCount: Int {
        statusesByPath.values.filter { $0.state == .waitingInput }.count
    }

    // MARK: - Alerts

    /// Acknowledges a project's alert. Called when the user clicks its row, which
    /// is the gesture that means "I have seen it".
    ///
    /// Deliberately does not care whether the underlying state is still there: a
    /// permission request that is still pending stays visible *in the panel*, where
    /// the answer buttons are. The strip reports what is new, not what is true.
    func clearAlert(forPath path: String) {
        guard alerts[path] != nil else { return }
        alerts.removeValue(forKey: path)
        // The banner goes with it: it was announcing this alert, and it is gone.
        notifier.withdraw(forPath: path)
        Log.debug("Avviso azzerato per \(( path as NSString).lastPathComponent)", category: .status)
    }

    /// The alert of a VS Code project, wherever its sessions were filed.
    func alert(for project: VSCodeProject) -> ClaudeAlert? {
        guard let path = project.path else { return nil }
        if let exact = alerts[path] { return exact }
        return alerts
            .filter { $0.key.hasPrefix(path + "/") }
            .values
            .max(by: { ClaudeAlert.moreUrgent($1, $0) })
    }

    func clearAlert(for project: VSCodeProject) {
        guard let path = project.path else { return }
        // Sessions of a project can be attributed to subdirectories of it, so the
        // alert may be filed under one of those.
        clearAlert(forPath: path)
        for key in alerts.keys where key.hasPrefix(path + "/") {
            clearAlert(forPath: key)
        }
    }

    func clearAllAlerts() {
        guard !alerts.isEmpty else { return }
        alerts = [:]
    }

    private func raise(_ kind: ClaudeAlertKind, for status: ClaudeProjectStatus, at now: Date) {
        let name = (status.projectPath as NSString).lastPathComponent
        let alert = ClaudeAlert(
            kind: kind,
            projectPath: status.projectPath,
            projectName: name,
            // The group is sorted most urgent first, so its head is the session
            // whose state the aggregate is reporting — the one that just changed.
            sessionID: sessionsByPath[status.projectPath]?.first?.sessionID,
            raisedAt: now,
            detail: status.detail ?? status.badge
        )
        alerts[status.projectPath] = alert

        // The pending session carries the command; the aggregate does not.
        let summary = waitingSessions.first { $0.projectPath == status.projectPath }?.toolSummary
        notifier.notify(alert, badge: status.badge, summary: summary)
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
        let grouped = Self.group(normalized, now: now, staleAfter: staleAfter)
        if grouped != sessionsByPath { sessionsByPath = grouped }

        // Only sessions that are genuinely still waiting: a request whose hook has
        // already given up is no longer answerable from here. Read from `grouped`,
        // so a record downgraded for going quiet cannot show answer buttons.
        let waiting = grouped.values
            .flatMap { $0 }
            .filter { $0.state == .waitingInput }
            .sorted { $0.updatedAt > $1.updatedAt }
        if waiting != waitingSessions { waitingSessions = waiting }

        let aggregated = Self.aggregate(grouped)
        guard aggregated != statusesByPath else { return }

        statusesByPath = aggregated
        handleTransitions(aggregated, now: now)

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

    /// Groups sessions by project, downgrading any record that claims to be busy
    /// but stopped reporting, and sorts each group most urgent first.
    private static func group(
        _ sessions: [ClaudeSessionStatus],
        now: Date,
        staleAfter: TimeInterval
    ) -> [String: [ClaudeSessionStatus]] {
        var byPath: [String: [ClaudeSessionStatus]] = [:]
        for session in sessions {
            let wentQuiet = now.timeIntervalSince(session.updatedAt) > staleAfter
                && (session.state == .working || session.state == .waitingInput)
            let adjusted = wentQuiet ? session.downgraded(to: .unknown) : session
            byPath[adjusted.projectPath, default: []].append(adjusted)
        }
        return byPath.mapValues(sortedByUrgency)
    }

    /// Most urgent first; ties go to the most recently updated.
    private static func sortedByUrgency(_ sessions: [ClaudeSessionStatus]) -> [ClaudeSessionStatus] {
        sessions.sorted { lhs, rhs in
            lhs.state == rhs.state ? lhs.updatedAt > rhs.updatedAt : lhs.state > rhs.state
        }
    }

    /// The per-project summary: the state of the most urgent session, and how many
    /// there are.
    private static func aggregate(
        _ grouped: [String: [ClaudeSessionStatus]]
    ) -> [String: ClaudeProjectStatus] {
        var result: [String: ClaudeProjectStatus] = [:]
        for (path, group) in grouped {
            // The groups arrive sorted, so the winner is simply the first.
            guard let winner = group.first else { continue }
            result[path] = ClaudeProjectStatus(
                projectPath: path,
                state: winner.state,
                detail: winner.detail,
                requestKind: winner.requestKind,
                updatedAt: group.map(\.updatedAt).max() ?? winner.updatedAt,
                sessionCount: group.count,
                isStale: winner.isStale
            )
        }
        return result
    }

    /// Turns state changes into alerts, and alerts into notifications.
    ///
    /// Only *transitions* raise anything, which is what separates "Claude finished"
    /// from "this session has been idle since it opened": both are `idle`, and only
    /// the first one arrives from `working`.
    private func handleTransitions(_ statuses: [String: ClaudeProjectStatus], now: Date) {
        for (path, status) in statuses {
            let previous = previousStates[path]
            previousStates[path] = status.state
            guard previous != status.state else { continue }

            switch status.state {
            case .waitingInput:
                raise(.waiting, for: status, at: now)

            case .idle:
                // A turn that ended. A session seen for the first time is also
                // `idle` and must not claim to have finished anything.
                if previous == .working || previous == .waitingInput {
                    raise(.done, for: status, at: now)
                }

            case .error:
                raise(.failed, for: status, at: now)

            case .unknown:
                // Downgraded from `working` after minutes of silence: the session is
                // stuck or died without a word, which is the other half of "it
                // stopped for whatever reason".
                if previous == .working {
                    raise(.failed, for: status, at: now)
                }

            case .working:
                // A new turn makes whatever was pending moot — including a `done`
                // the user never looked at.
                clearAlert(forPath: path)
            }
        }

        // Forget projects whose status files are gone, so a later re-appearance
        // counts as a fresh transition. Their alerts go too: the project row that
        // would clear one may have gone with it, and a light nobody can turn off is
        // worse than a missed one.
        for path in previousStates.keys where statuses[path] == nil {
            previousStates.removeValue(forKey: path)
            clearAlert(forPath: path)
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
