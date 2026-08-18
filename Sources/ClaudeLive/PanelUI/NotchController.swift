import AppKit
import Combine

/// Coordinates the notch surfaces: which screens get one, and their lifecycle.
///
/// One `NotchSurface` per screen. The set is recomputed — never rebuilt wholesale
/// — whenever the display configuration or the screen selection changes: a
/// surface that is still wanted on a still-connected screen is *updated in place*,
/// so plugging in a second monitor doesn't make the existing notch blink.
@MainActor
final class NotchController {
    private var surfaces: [NotchSurface] = []

    private let monitor: UsageMonitor
    private let projects: ProjectsMonitor
    private let status: ClaudeStatusStore
    private let settings: Settings
    private let actions: PanelActions

    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: Any?
    private var previewGeneration = 0

    /// True when there is any display to attach to — screens without a cutout get
    /// a drawn one, so in practice this is only false with no display at all.
    var isSupported: Bool { NotchGeometry.isAvailable }

    var isVisible: Bool { surfaces.contains { $0.isVisible } }

    init(
        monitor: UsageMonitor,
        projects: ProjectsMonitor,
        status: ClaudeStatusStore,
        settings: Settings,
        actions: PanelActions
    ) {
        self.monitor = monitor
        self.projects = projects
        self.status = status
        self.settings = settings
        self.actions = actions

        // Lid opened/closed, display attached, resolution changed: the notch may
        // appear, move or vanish.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncIfActive() }
        }

        // The strip reports unacknowledged alerts, so it follows them and the two
        // settings that decide how they look.
        status.$alerts
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshGlow() }
            }
            .store(in: &cancellables)

        settings.$glowEnabled
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshGlow() }
            }
            .store(in: &cancellables)

        settings.$glowStyles
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshGlow() }
            }
            .store(in: &cancellables)

        settings.$notchScreenSelection
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncIfActive() }
            }
            .store(in: &cancellables)

        settings.$notchScreenIDs
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncIfActive() }
            }
            .store(in: &cancellables)

        // The notch's size is part of the geometry, so a change here is a re-sync
        // rather than a re-layout: existing surfaces are updated in place. All four
        // inputs matter — the shared size, the per-screen sizes, and the switch that
        // decides which of the two applies.
        settings.$notchWidth
            .combineLatest(settings.$notchHeight)
            // Tuples are not Equatable, so dedupe on a value that is.
            .map { CGSize(width: $0, height: $1) }
            .removeDuplicates()
            .combineLatest(
                settings.$notchSizeByScreen.removeDuplicates(),
                settings.$usePerScreenNotchSize.removeDuplicates()
            )
            .dropFirst()
            .sink { [weak self] _, _, _ in
                Task { @MainActor in self?.syncIfActive() }
            }
            .store(in: &cancellables)
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    // MARK: - Lifecycle

    func show() {
        sync()
        guard surfaces.isEmpty else { return }
        Log.error("Modalità notch richiesta ma nessuno schermo disponibile", category: .panel)
    }

    func hide() {
        for surface in surfaces { surface.close() }
        surfaces = []
    }

    /// Expand/collapse every surface, for the menu and for diagnostics. Surfaces
    /// expanded by the user act independently; this is the deliberate exception.
    func setExpanded(_ expanded: Bool) {
        for surface in surfaces { surface.setExpanded(expanded) }
    }

    /// The notification strip, on every surface: it reports a state of the world,
    /// not of one display.
    private func setGlow(_ palette: NotchGlowPalette?) {
        for surface in surfaces { surface.setGlow(palette) }
    }

    /// Lights the strip for the most urgent unacknowledged alert, or turns it off.
    ///
    /// Thresholds are deliberately absent: they are not events in a project and
    /// there is nothing to click to acknowledge them, so they stay as a banner and
    /// as the colour of the rings.
    private func refreshGlow() {
        guard settings.glowEnabled, let alert = status.topAlert else {
            setGlow(nil)
            Log.debug("Segnale luminoso spento", category: .panel)
            return
        }
        let style = settings.glowStyle(for: alert.kind)
        setGlow(style.palette)
        Log.debug(
            "Segnale luminoso: \(alert.kind.rawValue) (\(style.mode.rawValue)) per «\(alert.projectName)»",
            category: .panel
        )
    }

    /// Lights it for a few seconds, for the «Prova» button in Settings.
    ///
    /// The generation counter is what makes a second tap restart the preview
    /// instead of having the first one's timer switch it off mid-way.
    func previewGlow(_ palette: NotchGlowPalette, seconds: TimeInterval = 8) {
        previewGeneration += 1
        let generation = previewGeneration
        setGlow(palette)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.previewGeneration == generation else { return }
            // Back to whatever is really pending, which may well be something.
            self.refreshGlow()
        }
    }

    func writeSnapshot(to url: URL) {
        surfaces.first?.writeSnapshot(to: url)
    }

    /// One line per surface: which screen, whether the notch is drawn, and the
    /// window rect actually on screen. The only way to tell "the setting had no
    /// effect" from "the setting does not apply here".
    func describeSurfaces() -> String {
        guard !surfaces.isEmpty else { return "nessuna superficie" }
        return surfaces.map { surface in
            let frame = surface.windowFrame
            return "«\(surface.geometry.screenName)» disegnato=\(surface.geometry.isVirtual ? "sì" : "no") notch=\(Int(surface.geometry.notchRect.width))×\(Int(surface.geometry.notchRect.height)) finestra=\(Int(frame.width))×\(Int(frame.height))"
        }.joined(separator: " | ")
    }

    // MARK: - Surface set

    private func syncIfActive() {
        guard settings.displayMode == .notch else { return }
        sync()
    }

    /// Brings `surfaces` in line with the current selection: update what stays,
    /// create what is new, close what is gone.
    private func sync() {
        let wanted = NotchGeometry.geometries(
            selection: settings.notchScreenSelection,
            chosenIDs: settings.notchScreenIDs,
            notchSize: { [settings] in settings.notchSize(forScreen: $0) }
        )
        let wantedIDs = Set(wanted.map(\.screenID))

        for surface in surfaces where !wantedIDs.contains(surface.screenID) {
            Log.debug("Notch rimosso da «\(surface.geometry.screenName)»", category: .panel)
            surface.close()
        }
        surfaces.removeAll { !wantedIDs.contains($0.screenID) }

        for geometry in wanted {
            if let existing = surfaces.first(where: { $0.screenID == geometry.screenID }) {
                existing.update(geometry: geometry)
                existing.show()
            } else {
                let surface = NotchSurface(
                    geometry: geometry,
                    monitor: monitor,
                    projects: projects,
                    status: status,
                    settings: settings,
                    actions: actions
                )
                surfaces.append(surface)
                surface.show()
            }
        }

        // A surface created just now knows nothing about a pending alert.
        refreshGlow()
    }
}
