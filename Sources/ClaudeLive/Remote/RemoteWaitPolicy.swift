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

    /// How long to wait when the screen is locked and the phone can answer.
    ///
    /// Two minutes, which is far more than the eleven seconds measured but far
    /// less than "until you come back": past a couple of minutes the answer
    /// stops being useful even if it arrives, because you have lost the thread
    /// of what was being asked.
    private static let awaySeconds: Double = 120

    @Published private(set) var isAway = false

    private let settings: Settings
    private let status: ClaudeStatusStore
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    init(settings: Settings, status: ClaudeStatusStore) {
        self.settings = settings
        self.status = status

        // These arrive whether or not the app is frontmost, which a menu-bar app
        // depends on: there is no window to notice a lock through.
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.update(locked: true) }
        })
        observers.append(center.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.update(locked: false) }
        })

        // Turning publishing off has to bring the wait back immediately:
        // otherwise Claude would keep freezing for two minutes waiting for a
        // phone that is no longer listening.
        settings.$remoteEnabled
            .sink { [weak self] _ in
                Task { @MainActor in self?.update(locked: Self.screenIsLocked()) }
            }
            .store(in: &cancellables)

        update(locked: Self.screenIsLocked())
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        for observer in observers { center.removeObserver(observer) }
    }

    private func update(locked: Bool) {
        // Away means *both*: not at the screen, and something able to answer in
        // your place. A locked screen with no paired phone is just an absent
        // user, and freezing Claude for two minutes would help nobody.
        let away = locked && settings.remoteEnabled
        guard away != isAway else { return }
        isAway = away
        status.awayWaitSeconds = away ? Self.awaySeconds : nil
        Log.info(
            away
                ? "Schermo bloccato: i permessi aspettano fino a \(Int(Self.awaySeconds))s per una risposta dal telefono"
                : "Sei tornato: i permessi tornano ad aspettare \(Int(settings.decisionWaitSeconds))s",
            category: .status
        )
    }

    /// Whether the screen is locked, for the state at launch — the notifications
    /// only report changes, and the app can start with the screen already locked.
    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
