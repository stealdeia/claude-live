import Foundation
import Combine
import AppKit

/// Decides how long a permission request should wait, based on whether you are
/// there to answer it.
///
/// This is the conclusion of the phase 0 measurement, and it exists because a
/// single number cannot be right. Transport to the phone takes 1.2 seconds; a
/// person noticing and answering took 11 while *expecting* the notification, and
/// is unbounded when not. Pick a long wait and every permission freezes Claude
/// for a minute while you sit in front of it. Pick a short one and answering
/// from the phone is impossible.
///
/// The way out is that the cost of waiting is not constant either. At the Mac,
/// waiting is obstruction — you would have answered in two seconds. Away from
/// it, a session frozen while nobody is watching costs nothing: it would have
/// sat idle regardless. So the wait follows presence, not a preference.
@MainActor
final class RemoteWaitPolicy: ObservableObject {

    /// How long to wait when you are away and the phone can answer.
    ///
    /// Was two minutes, on the reasoning that a later answer would arrive after
    /// you had lost the thread of the question. Watching a real attempt showed
    /// that reasoning to be wrong twice over: the app *shows* the question, so
    /// nothing is lost by answering late — and two minutes is not enough for
    /// what actually happens, which is noticing, unlocking the phone, opening
    /// the app, reading a command and deciding. One measured attempt took 169
    /// seconds and missed the window by a minute.
    ///
    /// Five minutes costs nothing when nobody is at the Mac: the session would
    /// have sat idle regardless. It only ever ends early, the moment you come
    /// back.
    /// Mezz'ora, non cinque minuti: sei fuori, il telefono è l'unica strada, e
    /// «cinque minuti per accorgersi della notifica» è una stima ottimistica di
    /// quanto ci si mette a tirare fuori il telefono dalla tasca. Finisce da sé
    /// appena torni alla tastiera.
    private static let awaySeconds: Double = 1800

    /// Untouched for this long counts as away, even with the screen unlocked.
    ///
    /// Locking is the honest signal but a bad requirement: habits are forgotten
    /// exactly when they matter, and someone who leaves without locking gets the
    /// worst outcome — told that Claude is waiting, unable to do anything about
    /// it. Three minutes is long enough not to fire while reading the screen,
    /// short enough to cover walking out in a hurry.
    private static let idleThreshold: TimeInterval = 180

    /// Cheap enough to run often, and being quick to notice a *return* matters
    /// more than noticing a departure: a held tool call ends the moment this
    /// clears.
    private static let pollInterval: TimeInterval = 5

    @Published private(set) var isAway = false

    private let settings: Settings
    private let status: ClaudeStatusStore
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var ticker: Timer?
    private var screenIsLocked = false

    init(settings: Settings, status: ClaudeStatusStore) {
        self.settings = settings
        self.status = status

        // These arrive whether or not the app is frontmost, which a menu-bar app
        // depends on: there is no window to notice a lock through.
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenIsLocked = true
                self?.update()
            }
        })
        observers.append(center.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenIsLocked = false
                self?.update()
            }
        })

        // Turning publishing off has to bring the wait back immediately:
        // otherwise Claude would keep freezing for two minutes waiting for a
        // phone that is no longer listening.
        settings.$remoteEnabled
            .sink { [weak self] _ in
                Task { @MainActor in self?.update() }
            }
            .store(in: &cancellables)

        screenIsLocked = Self.lockedNow()
        update()

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        // Common mode, or the check stops while a menu is open — precisely when
        // somebody is at the machine and the state most needs to be right.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        for observer in observers { center.removeObserver(observer) }
        ticker?.invalidate()
    }

    private func update() {
        // Away means *both*: not at the machine, and something able to answer in
        // your place. An absent user with no paired phone is just absent, and
        // freezing Claude for two minutes would help nobody.
        let elsewhere = screenIsLocked || Self.idleSeconds() >= Self.idleThreshold
        let away = elsewhere && settings.remoteEnabled

        guard away != isAway else { return }
        isAway = away
        status.awayWaitSeconds = away ? Self.awaySeconds : nil
        Log.important(
            away
                ? "Sei via (\(screenIsLocked ? "schermo bloccato" : "inattivo")): i permessi aspettano fino a \(Int(Self.awaySeconds))s per una risposta dal telefono"
                : "Sei tornato: i permessi tornano ad aspettare \(Int(settings.decisionWaitSeconds))s",
            category: .status
        )
    }

    /// Seconds since the last keyboard or mouse activity, from anywhere in the
    /// session — not just this app, which never has focus.
    private static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!
        )
    }

    /// Whether the screen is locked, for the state at launch — the notifications
    /// only report changes, and the app can start with the screen already locked.
    private static func lockedNow() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
