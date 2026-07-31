import Foundation
import Combine

/// Owns the polling loop, the last known snapshot and the threshold notifications.
/// The UI only ever reads from here.
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var state: UsageState = .idle
    @Published private(set) var rawHeaders: [String: String] = [:]
    /// When the next automatic refresh is due, for the panel's footer.
    @Published private(set) var nextRefreshAt: Date?

    private let client = UsageAPIClient()
    private let settings: Settings
    private let notifier: UsageNotifier

    private var timer: Timer?
    private var intervalObserver: AnyCancellable?
    private var inFlight = false

    init(settings: Settings, notifier: UsageNotifier) {
        self.settings = settings
        self.notifier = notifier
        loadCachedSnapshot()

        // Re-arm the timer whenever the interval setting changes.
        intervalObserver = settings.$refreshIntervalMinutes
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.restartTimer() }
            }
    }

    // MARK: - Lifecycle

    func start() {
        restartTimer()
        Task { await refresh(reason: "avvio") }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        nextRefreshAt = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = settings.refreshIntervalMinutes * 60
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: "timer") }
        }
        // A little slack lets the system coalesce our wakeups with others.
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        nextRefreshAt = Date().addingTimeInterval(interval)
        Log.debug("Timer riarmato: ogni \(Int(interval))s", category: .usage)
    }

    // MARK: - Refresh

    func refresh(reason: String) async {
        guard !inFlight else {
            Log.debug("Refresh «\(reason)» ignorato: già in corso", category: .usage)
            return
        }
        inFlight = true
        defer { inFlight = false }

        // Only show the spinner when there is nothing on screen yet; otherwise
        // the panel would flicker every five minutes.
        if snapshot == nil { state = .refreshing }

        let credentials: ClaudeCredentials
        do {
            // Off the main actor on purpose: reading the item can block for
            // minutes while macOS waits for the user to answer the keychain
            // access dialog, and blocking the main thread there freezes the
            // whole app — timers, watchers and UI included.
            credentials = try await Task.detached(priority: .utility) {
                try CredentialsStore.load()
            }.value
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            state = .unavailable(message: message)
            Log.error("Credenziali non disponibili: \(message)", category: .keychain)
            return
        }

        if credentials.isExpired {
            // Claude Code refreshes the token itself on its next run; we never
            // rotate it, to avoid invalidating the CLI's own copy.
            Log.info("Access token scaduto (\(credentials.expiresAt.map(Format.clock.string(from:)) ?? "?"))", category: .usage)
            state = .stale(reason: .tokenExpired)
            return
        }

        do {
            let result = try await client.probe(
                credentials: credentials,
                logHeaders: settings.debugLoggingEnabled || snapshot == nil
            )
            apply(result)
        } catch let error as UsageProbeError {
            handle(error)
        } catch {
            state = .stale(reason: .other(error.localizedDescription))
        }

        nextRefreshAt = Date().addingTimeInterval(settings.refreshIntervalMinutes * 60)
    }

    private func apply(_ result: UsageProbeResult) {
        snapshot = result.snapshot
        rawHeaders = result.rawHeaders
        state = .live
        persistCachedSnapshot(result.snapshot)

        let fiveHour = result.snapshot.fiveHour.map { Format.percent($0.utilization) } ?? "—"
        let sevenDay = result.snapshot.sevenDay.map { Format.percent($0.utilization) } ?? "—"
        Log.info("Usage aggiornato: 5h \(fiveHour), 7d \(sevenDay)\(result.snapshot.wasRateLimited ? " (429)" : "")", category: .usage)

        if settings.notificationsEnabled {
            notifier.evaluate(
                snapshot: result.snapshot,
                warn: settings.warnThreshold,
                danger: settings.dangerThreshold
            )
        }
    }

    private func handle(_ error: UsageProbeError) {
        switch error {
        case .unauthorized:
            Log.error("API 401/403: token rifiutato", category: .usage)
            state = .stale(reason: .tokenExpired)
        case .http(let code, let body):
            Log.error("API HTTP \(code): \(body ?? "-")", category: .usage)
            state = .stale(reason: .httpError(code))
        case .transport(let underlying):
            let nsError = underlying as NSError
            let offline = nsError.domain == NSURLErrorDomain && [
                NSURLErrorNotConnectedToInternet,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorTimedOut
            ].contains(nsError.code)
            Log.error("Errore di rete: \(underlying.localizedDescription)", category: .usage)
            state = .stale(reason: offline ? .offline : .other(underlying.localizedDescription))
        case .noRateLimitHeaders(let headers):
            Log.error("Nessun header rate-limit nella risposta. Header ricevuti: \(headers.keys.sorted().joined(separator: ", "))", category: .usage)
            state = .stale(reason: .other("Header di utilizzo assenti nella risposta"))
        }
    }

    // MARK: - Snapshot cache
    //
    // Persisted so that after a restart (or with the network down) the panel can
    // show the last known numbers with an explicit "stale" marker instead of
    // empty bars.

    private func loadCachedSnapshot() {
        guard let data = try? Data(contentsOf: Paths.usageCacheFile),
              let cached = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else { return }
        snapshot = cached
        Log.debug("Snapshot in cache caricato (\(Format.age(since: cached.fetchedAt)))", category: .usage)
    }

    private func persistCachedSnapshot(_ snapshot: UsageSnapshot) {
        Paths.ensureDirectories()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Paths.usageCacheFile, options: .atomic)
    }
}
