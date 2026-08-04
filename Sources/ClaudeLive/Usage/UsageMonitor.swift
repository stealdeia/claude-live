import Foundation
import Combine
import CoreGraphics

/// Thrown when a wait gives up. Not an error in the usual sense: the operation is
/// still running, we simply stopped waiting for it.
struct CredentialsTimeout: Error {}

/// Runs `work`, giving up after `seconds`.
///
/// The abandoned operation keeps going — `SecItemCopyMatching` cannot be
/// cancelled once macOS has put its dialog on screen. That is exactly why the
/// caller keeps a handle on it: the result is still useful whenever it lands.
private func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CredentialsTimeout()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CredentialsTimeout() }
        return first
    }
}

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

    /// Credentials are cached until Claude Code *writes a new keychain item*, which
    /// is detected from the item's modification date — an attributes-only read that
    /// never raises the macOS "allow access?" dialog.
    ///
    /// This is not a micro-optimisation. Every read of the item's **payload** can
    /// raise that dialog, and the grant does not always persist — on a Mac where
    /// the app's self-signed certificate is unknown it never does. Keying the cache
    /// on the modification date means the payload is read once per token refresh
    /// (~8h) instead of once per poll, *and* a refresh is noticed immediately
    /// rather than when our own clock says the old token should have died.
    private var cachedCredentials: ClaudeCredentials?
    private var cachedModificationDate: Date?

    /// The one access token the server has already rejected.
    ///
    /// Replaces the old "don't probe if it looks expired" rule, which is what made
    /// the app go quiet for half an hour: it refused to use a token that still had
    /// four minutes to live, then never asked again. Now the only token we decline
    /// to retry is one the API itself has turned down — and the moment Claude Code
    /// writes a different one, we try again.
    private var rejectedToken: String?

    /// A payload read in flight, shared so a second poll can never queue a second
    /// keychain dialog behind the first.
    private var pendingRead: Task<ClaudeCredentials, Error>?

    /// How long a poll waits for the keychain before giving up on it for now.
    ///
    /// `SecItemCopyMatching` blocks for as long as its dialog is on screen: once
    /// measured at **55 minutes**, during which `inFlight` stayed true and ten
    /// consecutive polls were skipped with "già in corso". The wait has to be
    /// bounded for the loop to survive an unanswered dialog.
    private let credentialsTimeout: TimeInterval = 20

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
            Task { @MainActor in await self?.refresh(reason: "timer", isAutomatic: true) }
        }
        // A little slack lets the system coalesce our wakeups with others.
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        nextRefreshAt = Date().addingTimeInterval(interval)
        Log.debug("Timer riarmato: ogni \(Int(interval))s", category: .usage)
    }

    // MARK: - Refresh

    /// `isAutomatic` marks polls nobody asked for — the timer and the wake
    /// notification. Only those are skipped while the screen is off; a refresh the
    /// user asked for always runs.
    func refresh(reason: String, isAutomatic: Bool = false) async {
        guard !inFlight else {
            Log.debug("Refresh «\(reason)» ignorato: già in corso", category: .usage)
            return
        }
        // The display being off means dark wake in all but the rarest case, and in
        // dark wake a keychain read that needs the dialog fails with "no UI
        // possible" — five such failures in one night, each one replacing the
        // numbers on screen with an error. Nobody is looking; skip the poll and
        // keep whatever we had.
        if isAutomatic, CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            Log.debug("Refresh «\(reason)» rinviato: schermo spento", category: .usage)
            return
        }

        inFlight = true
        defer { inFlight = false }

        // Only show the spinner when there is nothing on screen yet; otherwise
        // the panel would flicker every five minutes.
        if snapshot == nil { state = .refreshing }

        var credentials: ClaudeCredentials
        do {
            credentials = try await loadCredentials()
            if ProcessInfo.processInfo.environment["CLAUDELIVE_FORCE_BAD_TOKEN"] == "1" {
                credentials = credentials.withInvalidToken()
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            state = .unavailable(message: message)
            Log.error("Credenziali non disponibili: \(message)", category: .keychain)
            return
        }

        // The only token we skip is one the *server* has already refused. Its
        // stated expiry is not consulted here: clocks, slack and skew have all
        // been wrong before, and a request costs far less than half an hour of
        // silence.
        if credentials.accessToken == rejectedToken {
            Log.debug("Token già rifiutato dall'API e non ancora rinnovato: nessuna richiesta", category: .usage)
            state = .stale(reason: .tokenExpired)
            nextRefreshAt = Date().addingTimeInterval(settings.refreshIntervalMinutes * 60)
            return
        }

        if credentials.isPastExpiry {
            // Worth trying anyway, and worth knowing when it works.
            Log.info(
                "Access token oltre la scadenza dichiarata (\(credentials.expiresAt.map(Format.clock.string(from:)) ?? "?")): provo comunque",
                category: .usage
            )
        }

        do {
            let result = try await client.probe(
                credentials: credentials,
                logHeaders: settings.debugLoggingEnabled || snapshot == nil
            )
            rejectedToken = nil
            apply(result)
        } catch let error as UsageProbeError {
            // A rejected token is remembered rather than merely dropped: dropping
            // it made the next poll re-read the keychain, which on a Mac without a
            // persistent grant means a dialog every five minutes. Remembering it
            // means we wait quietly until Claude Code writes a new one.
            if case .unauthorized = error { rejectedToken = credentials.accessToken }
            handle(error)
        } catch {
            state = .stale(reason: .other(error.localizedDescription))
        }

        nextRefreshAt = Date().addingTimeInterval(settings.refreshIntervalMinutes * 60)
    }

    /// Returns the credentials, reading the keychain payload only when Claude Code
    /// has written a new one.
    ///
    /// The read happens off the main actor on purpose: it can block for minutes
    /// while macOS waits for the user to answer the keychain dialog, and blocking
    /// the main thread there freezes the whole app — timers, watchers, UI. Off the
    /// main actor it still must not block *this* function indefinitely, hence the
    /// timeout.
    private func loadCredentials() async throws -> ClaudeCredentials {
        // Cheap and dialog-free, so it can run on every poll.
        let modified = await Task.detached(priority: .utility) {
            CredentialsStore.modificationDate()
        }.value

        if let cached = cachedCredentials, let modified, modified == cachedModificationDate {
            return cached
        }

        let read = pendingRead ?? startCredentialsRead(modificationDate: modified)

        do {
            return try await withTimeout(credentialsTimeout) { try await read.value }
        } catch is CredentialsTimeout {
            // A dialog is presumably up. Carry on with what we have rather than
            // holding the poll open: an unanswered dialog once blocked ten
            // consecutive polls.
            if let cached = cachedCredentials {
                Log.info("Keychain lento (dialogo aperto?): uso le credenziali già lette", category: .keychain)
                return cached
            }
            throw CredentialsError.keychainFailure(errSecAuthFailed)
        }
    }

    /// Starts the one shared payload read. Kept in `pendingRead` so a later poll
    /// waits on the same dialog instead of stacking a second one behind it, and so
    /// its result is still picked up if it lands after the timeout.
    private func startCredentialsRead(modificationDate: Date?) -> Task<ClaudeCredentials, Error> {
        let read = Task.detached(priority: .utility) {
            try CredentialsStore.load()
        }
        pendingRead = read

        Task { @MainActor in
            defer { if self.pendingRead == read { self.pendingRead = nil } }
            guard let loaded = try? await read.value else { return }
            self.cachedCredentials = loaded
            self.cachedModificationDate = modificationDate
            if let expiry = loaded.expiresAt {
                Log.info(
                    "Credenziali in cache fino a \(Format.clock.string(from: expiry))",
                    category: .keychain
                )
            }
        }

        return read
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
