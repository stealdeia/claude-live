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
    /// Whether the keychain will hand over the credentials without asking. Nil
    /// until the first probe lands.
    @Published private(set) var keychainAuthorization: KeychainAuthorization?

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

    /// Armed while the token is rejected: checks the keychain item's modification
    /// date every 30 s (attributes-only, milliseconds, no dialog) so the panel
    /// comes back within seconds of Claude Code writing a fresh token, instead of
    /// waiting for the next five-minute poll.
    ///
    /// This is the *whole* recovery strategy, deliberately. The app used to renew
    /// the token itself (0.5.1, 2026-08-07) and the result was a rotation war:
    /// Claude Code holds its refresh token in memory, so each renewal from here
    /// invalidated it, logged the user out of their own CLI, and every 401→renew
    /// cycle rewrote the keychain — a password dialog every five minutes. The app
    /// must never write Claude Code's credentials; it waits for their owner.
    private var recoveryTimer: Timer?

    /// A payload read in flight, shared so a second poll can never queue a second
    /// keychain dialog behind the first.
    private var pendingRead: Task<ClaudeCredentials, Error>?

    /// True while an attributes query is outstanding. One that is stuck behind a
    /// keychain dialog must not be joined by a new one on every poll.
    private var readingModificationDate = false

    /// How long a poll waits for the keychain before giving up on it for now.
    ///
    /// `SecItemCopyMatching` blocks for as long as its dialog is on screen: once
    /// measured at **55 minutes**, during which `inFlight` stayed true and ten
    /// consecutive polls were skipped with "già in corso". The wait has to be
    /// bounded for the loop to survive an unanswered dialog.
    private let credentialsTimeout: TimeInterval = 20

    /// Short on purpose: reading the item's attributes takes milliseconds when the
    /// keychain is free (measured: 8 ms), so anything slower means it is blocked and
    /// waiting longer buys nothing.
    private let attributeTimeout: TimeInterval = 3

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
        // Probed before the first read, so the log says whether the dialog that may
        // follow was expected.
        Task {
            await refreshKeychainAuthorization()
            await refresh(reason: "avvio")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        nextRefreshAt = nil
    }

    /// Refreshes once the Mac is genuinely back, not merely awake.
    ///
    /// `didWakeNotification` fires before the display comes on — and a refresh
    /// that lands in that gap is skipped as "screen off", which is what left the
    /// panel showing numbers 14 hours old on the morning of 2026-08-07. So the
    /// wake signal now waits for the display instead of spending itself on it,
    /// and gives up after a couple of minutes, which is a dark wake.
    func refreshAfterWake() async {
        for _ in 0..<60 {
            if CGDisplayIsAsleep(CGMainDisplayID()) == 0 {
                await refresh(reason: "risveglio")
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        Log.debug("Risveglio senza schermo acceso: nessun refresh", category: .usage)
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
            if settings.notificationsEnabled {
                notifier.notifyProblem("Non riesco a leggere le credenziali di Claude Code: \(message)")
            }
            return
        }

        // Still holding the token the server refused: there is nothing to ask.
        // The recovery watch is what gets us out of here, the moment Claude Code
        // writes a fresh token.
        if credentials.accessToken == rejectedToken {
            Log.debug("Token già rifiutato dall'API: aspetto che Claude Code lo rinnovi", category: .usage)
            state = .stale(reason: .tokenExpired)
            armRecoveryWatch()
            nextRefreshAt = Date().addingTimeInterval(settings.refreshIntervalMinutes * 60)
            return
        }

        if credentials.isPastExpiry {
            // Worth trying anyway, and worth knowing when it works. The server is
            // the authority on whether a token is alive: clocks, slack and skew
            // have all been wrong before.
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
            // A rejected token is remembered rather than merely dropped:
            // dropping it made the next poll re-read the keychain, which on a
            // Mac without a persistent grant means a dialog every five
            // minutes. Remembering it means we stay quiet until there is a
            // genuinely different token to try.
            if case .unauthorized = error {
                rejectedToken = credentials.accessToken
            }
            handle(error)
        } catch {
            state = .stale(reason: .other(error.localizedDescription))
        }

        nextRefreshAt = Date().addingTimeInterval(settings.refreshIntervalMinutes * 60)
    }

    // MARK: - Recovery watch

    /// Checks every 30 s whether Claude Code has written new credentials, and
    /// refreshes as soon as it has. Attribute-only reads: milliseconds, no
    /// dialog, no network — cheap enough to run until recovery, harmless if the
    /// Mac goes back to sleep.
    private func armRecoveryWatch() {
        guard recoveryTimer == nil else { return }
        Log.debug("Controllo credenziali ogni 30s finché Claude Code non scrive un token nuovo", category: .usage)
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.recoveryTick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        recoveryTimer = timer
    }

    private func disarmRecoveryWatch() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
    }

    private func recoveryTick() async {
        // Recovery is only about a refused token; other stale reasons (offline,
        // HTTP errors) already retry on the normal timer.
        guard rejectedToken != nil else {
            disarmRecoveryWatch()
            return
        }
        let modified = await modificationDate()
        guard let modified, modified != cachedModificationDate else { return }
        Log.info("Claude Code ha scritto credenziali nuove: riprovo subito", category: .usage)
        await refresh(reason: "nuove credenziali")
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
        let modified = await modificationDate()

        // `modified == nil` means "we could not find out", not "it changed": with a
        // usable copy in hand there is no reason to go and disturb the keychain.
        if let cached = cachedCredentials {
            guard let modified, modified != cachedModificationDate else { return cached }
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

    /// When Claude Code last wrote the keychain item, or nil if it could not be
    /// determined in time.
    ///
    /// An attributes-only query decrypts nothing and cannot raise the "allow
    /// access?" dialog *by itself* — but while such a dialog is on screen the whole
    /// keychain serialises behind it, so even this query blocks. Observed live: a
    /// dialog left unanswered stopped the polling loop entirely, because 0.4.0 put
    /// the timeout only on the payload read and left this one unbounded.
    /// Probes the keychain and records the answer. Never shows a dialog.
    ///
    /// Logged with the bundle's path, because the path *is* the identity as far as
    /// the keychain is concerned, and "which copy of the app is running" is the one
    /// question that explains a dialog nobody asked for.
    func refreshKeychainAuthorization() async {
        let state = (try? await KeychainQueue.run { CredentialsStore.authorizationState() })
            ?? .failed(errSecInternalError)
        keychainAuthorization = state

        let path = Bundle.main.bundlePath
        switch state {
        case .granted:
            Log.info("Accesso al portachiavi concesso a «\(path)»", category: .keychain)
        case .notAuthorized:
            Log.error(
                "Accesso al portachiavi non concesso a «\(path)»: alla prossima lettura macOS chiederà la password. "
                + "L'autorizzazione è per percorso, quindi vale solo per la copia a cui è stata data.",
                category: .keychain
            )
        case .notFound:
            Log.error("Nessuna credenziale Claude Code nel portachiavi", category: .keychain)
        case .failed(let status):
            Log.error("Sonda portachiavi fallita: codice \(status)", category: .keychain)
        }
    }

    private func modificationDate() async -> Date? {
        // The flag, not the timeout, is what bounds this: giving up waiting does
        // not unblock the query, so without it every poll would leave another
        // blocked thread behind for as long as the dialog stayed up.
        guard !readingModificationDate else {
            Log.debug("Attributi keychain già in lettura: query saltata", category: .keychain)
            return nil
        }
        readingModificationDate = true

        let read: Task<Date?, Never> = Task { [weak self] in
            let value = try? await KeychainQueue.run { CredentialsStore.modificationDate() }
            self?.readingModificationDate = false
            return value
        }

        do {
            return try await withTimeout(attributeTimeout) { await read.value }
        } catch {
            Log.debug("Data di modifica del keychain non leggibile in tempo", category: .keychain)
            return nil
        }
    }

    /// Starts the one shared payload read. Kept in `pendingRead` so a later poll
    /// waits on the same dialog instead of stacking a second one behind it, and so
    /// its result is still picked up if it lands after the timeout.
    private func startCredentialsRead(modificationDate: Date?) -> Task<ClaudeCredentials, Error> {
        let startedAt = Date()

        let read = Task<ClaudeCredentials, Error> {
            try await KeychainQueue.run { try CredentialsStore.load() }
        }
        pendingRead = read

        Task { @MainActor in
            defer { if self.pendingRead == read { self.pendingRead = nil } }
            guard let loaded = try? await read.value else { return }
            self.cachedCredentials = loaded
            self.cachedModificationDate = modificationDate

            // A silent read takes milliseconds; anything slow was spent with a
            // password dialog on screen waiting for an answer. Recorded because
            // "it asked me again" is otherwise impossible to confirm afterwards.
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed > 1 {
                Log.error(
                    String(format: "Lettura credenziali durata %.1fs: macOS ha chiesto l'autorizzazione", elapsed),
                    category: .keychain
                )
            }

            // Probed *after* the read, never before: a read that just succeeded may
            // have succeeded because the user answered a dialog, so the state from
            // before it says nothing about now — and the probe must not be in flight
            // while the read is, or it would suppress the dialog it is describing.
            await self.refreshKeychainAuthorization()
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
        disarmRecoveryWatch()
        notifier.clearProblem()
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
            armRecoveryWatch()
            if settings.notificationsEnabled {
                notifier.notifyProblem(
                    "Il token di Claude Code è scaduto. Usa Claude Code (basta un comando): appena scrive il token nuovo, riprendo da solo."
                )
            }
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
