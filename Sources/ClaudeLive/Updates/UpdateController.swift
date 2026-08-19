import AppKit
import Sparkle
import ClaudeLiveKit

/// Automatic updates, via Sparkle.
///
/// The app is signed with a self-signed certificate, so Gatekeeper makes the
/// recipient approve it once on first launch. Sparkle's own EdDSA signature is
/// what actually protects updates: the private half never leaves the developer's
/// keychain, and the app refuses any download that does not verify against the
/// public key embedded in Info.plist. That check is independent of Apple's
/// notarisation, so it works exactly the same for a self-signed build.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var lastCheckDescription: String = "mai"
    @Published private(set) var isCheckInProgress = false

    /// Built after `super.init()`: `SPUUpdater.delegate` is read-only, so the
    /// delegate has to be handed to the controller's initialiser, which means it
    /// cannot be created before `self` exists.
    private var controller: SPUStandardUpdaterController!

    /// The version the running bundle reports, for display.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    override init() {
        super.init()

        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        do {
            try controller.updater.start()
            Log.info("Sparkle avviato (versione \(Self.currentVersion), feed \(feedURLDescription))")
        } catch {
            Log.error("Sparkle non avviato: \(error.localizedDescription)")
        }
        refreshLastCheckDescription()
    }

    private var feedURLDescription: String {
        Bundle.main.infoDictionary?["SUFeedURL"] as? String ?? "non configurato"
    }

    /// Whether Sparkle checks on its own schedule.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            Log.info("Controllo automatico aggiornamenti: \(newValue ? "attivo" : "disattivo")")
        }
    }

    /// User-initiated check. Goes through the standard controller so Sparkle also
    /// reports "you're up to date", which its silent background check does not.
    func checkForUpdates() {
        isCheckInProgress = true
        // An LSUIElement app has to activate explicitly, or Sparkle's dialogs
        // open behind everything.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Checks without showing any UI: used by the diagnostics env var, and safe
    /// to call from a script because it only reports through the delegate.
    func checkSilently() {
        isCheckInProgress = true
        controller.updater.checkForUpdateInformation()
    }

    private func refreshLastCheckDescription() {
        guard let date = controller.updater.lastUpdateCheckDate else {
            lastCheckDescription = "mai"
            return
        }
        lastCheckDescription = Format.age(since: date)
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        let count = appcast.items.count
        Task { @MainActor in
            Log.info("Appcast caricato: \(count) voci")
            self.isCheckInProgress = false
            self.refreshLastCheckDescription()
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            Log.info("Nessun aggiornamento disponibile")
            self.isCheckInProgress = false
            self.refreshLastCheckDescription()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            Log.info("Aggiornamento trovato: \(version)")
            self.isCheckInProgress = false
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let description = error.localizedDescription
        Task { @MainActor in
            Log.error("Controllo aggiornamenti interrotto: \(description)")
            self.isCheckInProgress = false
            self.refreshLastCheckDescription()
        }
    }
}
