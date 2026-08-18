import AppKit
import ApplicationServices
import Combine

/// Turns the signal off when the user goes to the project's own window, instead of
/// making them come through the panel.
///
/// ## Why this needs a permission, and works without it anyway
///
/// Knowing *which* editor window is in front means reading its **title**, and macOS
/// protects window titles: `CGWindowListCopyWindowInfo` omits them without Screen
/// Recording, and the Accessibility API refuses without its own permission. Without
/// one of the two, all this app can know is "an editor is frontmost" — not which
/// project it is showing.
///
/// So there are two levels, and neither is a lie to the user:
///   * **Accessibility granted** — the focused window's title is read and resolved to
///     a project through the same catalog the project list uses, so exactly that
///     project's alert is cleared, and switching between editor windows works too;
///   * **not granted** — an editor coming to the front clears the alert only when
///     there is exactly one, where "the user went to look at it" is a fair guess and
///     the cost of being wrong is a light going out a little early.
///
/// The permission is never demanded: the app asks once from Settings, if the user
/// wants the precise behaviour.
@MainActor
final class FrontProjectWatcher {
    private let status: ClaudeStatusStore
    private let settings: Settings

    /// Resolves a window title to a project, exactly as the project list does.
    private var catalog = WorkspaceCatalog()
    private var catalogLoadedAt: Date = .distantPast

    /// How long an alert stays lit before being in front of its project can put it
    /// out.
    ///
    /// Without this the common case is the worst one: you are already working in the
    /// project when Claude finishes, so the check fires within a second and a half
    /// and the strip does a *flash* — neither shown nor hidden, and it reads as a
    /// glitch. Two full pulses (2.6s each) is long enough to register as a
    /// deliberate signal and short enough not to nag.
    private let minimumVisible: TimeInterval = 5

    /// When an editor last *became* frontmost.
    ///
    /// The imprecise path needs it: "you switched here after it lit up" is a fair
    /// reason to put out the only pending alert, while "an editor happens to be in
    /// front" is not. Keeping the instant, rather than acting on the notification
    /// itself, is what lets the check run again later — an alert younger than
    /// `minimumVisible` at the moment you arrived would otherwise never be cleared
    /// by focus at all.
    private var editorActivatedAt: Date = .distantPast

    private var activationObserver: Any?
    /// Runs only while something is pending — see `alertsChanged`.
    private var poll: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(status: ClaudeStatusStore, settings: Settings) {
        self.status = status
        self.settings = settings
    }

    static var isTrustedForTitles: Bool { AXIsProcessTrusted() }

    /// Opens the system prompt, once. macOS shows it only the first time; after
    /// that it silently does nothing, which is why Settings also links to the
    /// pane.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func start() {
        Log.info(
            "Riconoscimento finestra in primo piano: \(Self.isTrustedForTitles ? "esatto (permesso Accessibilità concesso)" : "approssimato (nessun permesso Accessibilità)")",
            category: .status
        )

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.noteActivation()
                self?.check()
            }
        }

        // Switching between two editor windows raises no notification at all, so a
        // slow poll covers it. Armed only while there is an alert to clear, which
        // is why it can be this simple.
        status.$alerts
            .map(\.isEmpty)
            .removeDuplicates()
            .sink { [weak self] isEmpty in
                Task { @MainActor in self?.setPolling(!isEmpty) }
            }
            .store(in: &cancellables)
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        setPolling(false)
        cancellables.removeAll()
    }

    private func setPolling(_ wanted: Bool) {
        guard wanted != (poll != nil) else { return }
        guard wanted else {
            poll?.invalidate()
            poll = nil
            return
        }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    // MARK: - Checking

    private func noteActivation() {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              EditorApp.all.contains(where: { $0.bundleID == bundleID })
        else { return }
        editorActivatedAt = Date()
    }

    private func check() {
        guard settings.clearAlertsOnFocus, !status.alerts.isEmpty else { return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              EditorApp.all.contains(where: { $0.bundleID == bundleID })
        else { return }

        if let path = focusedProjectPath(pid: front.processIdentifier) {
            guard let alert = status.alerts[path], hasBeenSeen(alert) else { return }
            Log.debug(
                "Segnale spento: «\((path as NSString).lastPathComponent)» è la finestra in primo piano",
                category: .status
            )
            status.clearAlert(forPath: path)
            return
        }

        // No title available, so which project is in front is unknown. Putting out
        // the only alert there is stays defensible when the user came to the editor
        // *after* it lit up; guessing between several does not.
        guard status.alerts.count == 1,
              let (path, alert) = status.alerts.first,
              editorActivatedAt > alert.raisedAt,
              hasBeenSeen(alert)
        else { return }
        Log.debug(
            "Segnale spento: sei passato all'editor e c'era un solo avviso (senza permesso Accessibilità)",
            category: .status
        )
        status.clearAlert(forPath: path)
    }

    /// Whether the alert has been on screen long enough to have been noticed.
    private func hasBeenSeen(_ alert: ClaudeAlert) -> Bool {
        Date().timeIntervalSince(alert.raisedAt) >= minimumVisible
    }

    /// The project shown by the frontmost window of `pid`, if its title can be read.
    private func focusedProjectPath(pid: pid_t) -> String? {
        guard Self.isTrustedForTitles else { return nil }

        let app = AXUIElementCreateApplication(pid)
        // The main thread must never be held hostage by an editor that is busy
        // indexing: without this the default timeout is six seconds.
        AXUIElementSetMessagingTimeout(app, 0.25)

        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { return nil }

        // swiftlint:disable:next force_cast — the type id was just checked.
        let window = windowValue as! AXUIElement
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String,
              !title.isEmpty
        else { return nil }

        refreshCatalogIfStale()
        return VSCodeCLI.resolveProject(fromTitle: title, catalog: catalog).path
    }

    /// The catalog only changes when a workspace is opened for the first time.
    private func refreshCatalogIfStale() {
        guard Date().timeIntervalSince(catalogLoadedAt) > 60 else { return }
        catalog = WorkspaceCatalog.load(for: EditorApp.all)
        catalogLoadedAt = Date()
    }
}
