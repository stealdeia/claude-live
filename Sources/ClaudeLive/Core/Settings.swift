import Foundation
import Combine

enum PanelAnchor: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight, free

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: return "Alto a sinistra"
        case .topRight: return "Alto a destra"
        case .bottomLeft: return "Basso a sinistra"
        case .bottomRight: return "Basso a destra"
        case .free: return "Libero (trascinato)"
        }
    }
}

/// Flat, versioned on-disk representation. Keeping it separate from the
/// observable object means adding a field never breaks decoding of an older file.
private struct SettingsData: Codable {
    var refreshIntervalMinutes: Double?
    var warnThreshold: Double?
    var dangerThreshold: Double?
    var notificationsEnabled: Bool?
    var notifyOnWaitingInput: Bool?
    var notificationSound: String?
    var notifyOnDone: Bool?
    var notifyOnFailure: Bool?
    var glowEnabled: Bool?
    var clearAlertsOnFocus: Bool?
    var glowStyles: [String: GlowStyle]?
    var debugLoggingEnabled: Bool?
    var panelOpacity: Double?
    var panelVisible: Bool?
    var panelCollapsed: Bool?
    var panelAnchor: PanelAnchor?
    var displayMode: DisplayMode?
    var theme: AppTheme?
    var notchExpandOnHover: Bool?
    var notchShowsControls: Bool?
    var notchScale: Double?
    var notchWidth: Double?
    var notchHeight: Double?
    var usePerScreenNotchSize: Bool?
    var notchSizeByScreen: [String: NotchSize]?
    /// Names used in 0.3.2 only, when the setting applied to drawn notches alone.
    /// Read so an existing file keeps its values; never written again.
    var virtualNotchWidth: Double?
    var virtualNotchHeight: Double?
    var notchScreenSelection: NotchScreenSelection?
    var notchScreenIDs: [String]?
    var panelTopLeftX: Double?
    var panelTopLeftY: Double?
    var projectsRefreshMinutes: Double?
    var showPercentageInMenuBar: Bool?
    var showMenuBarIcon: Bool?
    var launchAtLogin: Bool?
    var hasCompletedOnboarding: Bool?
    var decisionWaitSeconds: Double?
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    /// How often the usage probe runs. Clamped to something sane so a stray
    /// value in the JSON can't turn the app into a request loop.
    /// Note on the clamping pattern used here and for `panelOpacity`: assigning
    /// to the property inside its own `didSet` re-enters the observer, so the
    /// guard is what stops it — the second pass finds the value already clamped
    /// and falls through to persisting.
    @Published var refreshIntervalMinutes: Double = 5 {
        didSet {
            let clamped = refreshIntervalMinutes.clamped(to: 1...60)
            guard clamped == refreshIntervalMinutes else {
                refreshIntervalMinutes = clamped
                return
            }
            schedulePersist()
        }
    }

    /// Utilization fraction (0…1) at which a bar turns yellow.
    @Published var warnThreshold: Double = 0.75 { didSet { schedulePersist() } }
    /// Utilization fraction (0…1) at which a bar turns red.
    @Published var dangerThreshold: Double = 0.90 { didSet { schedulePersist() } }

    @Published var notificationsEnabled: Bool = true { didSet { schedulePersist() } }

    /// Notify when Claude Code starts waiting for input in some project.
    @Published var notifyOnWaitingInput: Bool = true { didSet { schedulePersist() } }

    /// Notify when a turn ends normally.
    ///
    /// On, like the others. Worth knowing that this is the noisiest of the three —
    /// a turn ends every few minutes while you work — and that the strip around the
    /// notch says the same thing without interrupting, so this is the one to turn
    /// off first if the banners get in the way.
    @Published var notifyOnDone: Bool = true { didSet { schedulePersist() } }

    /// Notify when a turn dies on an error, or a working session goes silent.
    @Published var notifyOnFailure: Bool = true { didSet { schedulePersist() } }

    /// Whether bringing a project's editor window to the front counts as having
    /// seen its alert. See `FrontProjectWatcher` for what this can and cannot know
    /// without the Accessibility permission.
    @Published var clearAlertsOnFocus: Bool = true { didSet { schedulePersist() } }

    /// Whether the notch shows the luminous strip at all.
    @Published var glowEnabled: Bool = true { didSet { schedulePersist() } }

    /// One style per kind of alert, keyed by `ClaudeAlertKind.rawValue`.
    ///
    /// A kind with no entry uses its default, so the file only ever holds what the
    /// user actually changed.
    @Published var glowStyles: [String: GlowStyle] = [:] { didSet { schedulePersist() } }

    /// Sound for every notification this app posts. Empty means the system
    /// default; anything else is a file name in /System/Library/Sounds — see
    /// `NotificationSound`.
    @Published var notificationSound: String = NotificationSound.systemDefault {
        didSet {
            // A name whose file is gone would deliver a silent notification, so
            // it falls back rather than being stored.
            guard NotificationSound.isKnown(notificationSound) else {
                notificationSound = NotificationSound.systemDefault
                return
            }
            schedulePersist()
        }
    }

    @Published var debugLoggingEnabled: Bool = false {
        didSet {
            Log.fileLoggingEnabled = debugLoggingEnabled
            schedulePersist()
        }
    }

    @Published var panelOpacity: Double = 0.94 {
        didSet {
            let clamped = panelOpacity.clamped(to: 0.35...1.0)
            guard clamped == panelOpacity else {
                panelOpacity = clamped
                return
            }
            schedulePersist()
        }
    }

    /// Floating panel or notch. Switching rebuilds the visible surface.
    @Published var displayMode: DisplayMode = .floating { didSet { schedulePersist() } }

    /// Appearance of the floating panel. Ignored in notch mode (always black).
    @Published var theme: AppTheme = .system { didSet { schedulePersist() } }

    /// Whether hovering the notch strips expands the detail panel, in addition
    /// to the explicit buttons.
    @Published var notchExpandOnHover: Bool = false { didSet { schedulePersist() } }

    /// Whether the chevron and the projects button are drawn beside the rings.
    ///
    /// With them hidden the bar is just the two rings hugging the cutout, and the
    /// rings themselves open the detail — clicking anywhere outside it closes it
    /// again, so nothing becomes unreachable.
    @Published var notchShowsControls: Bool = true { didSet { schedulePersist() } }

    /// Size multiplier for the notch rings and their labels. The strips widen to
    /// match, so the whole surface grows a little with it.
    @Published var notchScale: Double = 1.0 {
        didSet {
            let clamped = notchScale.clamped(to: 0.9...1.5)
            guard clamped == notchScale else {
                notchScale = clamped
                return
            }
            schedulePersist()
        }
    }

    /// Size of the *drawn* notch, on screens that have no cutout.
    ///
    /// Only the drawn one: where the hardware has a hole, its measurements win —
    /// a bar of a different size would hang past the hole instead of continuing it.
    @Published var notchWidth: Double = NotchGeometry.defaultNotchSize.width {
        didSet {
            let clamped = notchWidth.clamped(to: NotchGeometry.widthRange)
            guard clamped == notchWidth else {
                notchWidth = clamped
                return
            }
            schedulePersist()
        }
    }

    @Published var notchHeight: Double = NotchGeometry.defaultNotchSize.height {
        didSet {
            let clamped = notchHeight.clamped(to: NotchGeometry.heightRange)
            guard clamped == notchHeight else {
                notchHeight = clamped
                return
            }
            schedulePersist()
        }
    }

    func glowStyle(for kind: ClaudeAlertKind) -> GlowStyle {
        glowStyles[kind.rawValue] ?? .default(for: kind)
    }

    func setGlowStyle(_ style: GlowStyle, for kind: ClaudeAlertKind) {
        guard glowStyles[kind.rawValue] != style else { return }
        // A style that *is* the default is stored as "nothing", so the file keeps
        // holding only what the user actually changed — «Ripristina» has to leave
        // the settings as they were before the first change, not as an explicit copy
        // of the defaults that would then survive a change of defaults.
        if style == .default(for: kind) {
            glowStyles.removeValue(forKey: kind.rawValue)
        } else {
            glowStyles[kind.rawValue] = style
        }
    }

    /// Whether each screen keeps its own size instead of sharing one.
    ///
    /// Off by default, but the reason it exists is that sharing one size is wrong
    /// as soon as there are two displays: a bar sized for a 1512pt laptop panel is
    /// a different thing on a 1920pt monitor.
    @Published var usePerScreenNotchSize: Bool = false { didSet { schedulePersist() } }

    /// Per-display sizes, keyed by `ScreenIdentity`. A display with no entry falls
    /// back to the shared size, so turning the switch on changes nothing until a
    /// slider is actually moved.
    @Published var notchSizeByScreen: [String: NotchSize] = [:] { didSet { schedulePersist() } }

    /// The shared size, used when per-screen sizes are off or unset.
    var notchSize: CGSize {
        CGSize(width: notchWidth, height: notchHeight)
    }

    /// The size to use on one display.
    func notchSize(forScreen id: String) -> CGSize {
        guard usePerScreenNotchSize, let stored = notchSizeByScreen[id] else { return notchSize }
        return stored.cgSize
    }

    /// Writes one display's size. Writing while the shared mode is on would be
    /// silently ignored, so it switches to per-screen sizes as well: the slider the
    /// user just moved has to be the one that takes effect.
    func setNotchSize(_ size: CGSize, forScreen id: String) {
        let clamped = NotchSize(
            width: Double(size.width).clamped(to: NotchGeometry.widthRange),
            height: Double(size.height).clamped(to: NotchGeometry.heightRange)
        )
        guard notchSizeByScreen[id] != clamped else { return }
        notchSizeByScreen[id] = clamped
    }

    /// Which displays show a notch surface.
    @Published var notchScreenSelection: NotchScreenSelection = .automatic { didSet { schedulePersist() } }

    /// Stable display identifiers (see `ScreenIdentity`) used when the selection
    /// is `.chosen`. Identifiers of monitors that are not connected right now are
    /// kept: they become live again when the monitor comes back.
    @Published var notchScreenIDs: [String] = [] { didSet { schedulePersist() } }

    @Published var panelVisible: Bool = true { didSet { schedulePersist() } }
    @Published var panelCollapsed: Bool = false { didSet { schedulePersist() } }
    @Published var panelAnchor: PanelAnchor = .topRight { didSet { schedulePersist() } }

    /// Last free-drag position, stored as the panel's **top-left** corner in
    /// AppKit screen coordinates. Storing the top-left rather than the origin
    /// (bottom-left) makes it independent of the panel's height, so a content
    /// resize can no longer shift the panel.
    @Published var panelTopLeft: CGPoint? = nil { didSet { schedulePersist() } }

    /// Optional periodic project refresh, in minutes. 0 = only on real events.
    ///
    /// Default off on purpose: each refresh runs `code --status`, which briefly
    /// registers a second VS Code instance with LaunchServices — visible as an
    /// icon flashing in the Dock. Event-driven refresh has no such cost.
    @Published var projectsRefreshMinutes: Double = 0 {
        didSet {
            let clamped = projectsRefreshMinutes.clamped(to: 0...60)
            guard clamped == projectsRefreshMinutes else {
                projectsRefreshMinutes = clamped
                return
            }
            schedulePersist()
        }
    }

    @Published var showPercentageInMenuBar: Bool = true { didSet { schedulePersist() } }

    /// Whether the app keeps an item in the menu bar at all.
    ///
    /// Removable because in notch mode the same numbers are on screen already, and
    /// a second copy of them is just clutter. Everything the menu can do is also in
    /// Settings, which the panel's gear opens — and re-launching the app opens
    /// Settings too, so the item can always be brought back.
    @Published var showMenuBarIcon: Bool = true { didSet { schedulePersist() } }

    /// Mirrors `SMAppService`; the service is the source of truth, this is just
    /// what the UI binds to.
    @Published var launchAtLogin: Bool = false {
        didSet {
            guard !isLoading, launchAtLogin != LoginItem.isEnabled else {
                schedulePersist()
                return
            }
            _ = LoginItem.setEnabled(launchAtLogin)
            schedulePersist()
        }
    }

    /// False until the first-run wizard has been completed or skipped.
    @Published var hasCompletedOnboarding: Bool = false { didSet { schedulePersist() } }

    /// How long a Claude Code permission request waits for an answer from the
    /// panel before falling back to the usual terminal prompt. 0 disables it.
    ///
    /// The hook is blocking, so this is also how long the terminal stays silent:
    /// a longer wait makes the panel more useful and the terminal less responsive.
    @Published var decisionWaitSeconds: Double = 8 {
        didSet {
            let clamped = decisionWaitSeconds.clamped(to: 0...60)
            guard clamped == decisionWaitSeconds else {
                decisionWaitSeconds = clamped
                return
            }
            schedulePersist()
        }
    }

    private var persistTask: Task<Void, Never>?
    private var isLoading = false

    private init() {
        load()
        Log.fileLoggingEnabled = debugLoggingEnabled
        // The service is authoritative: the user may have toggled the login item
        // in System Settings since the last launch.
        isLoading = true
        launchAtLogin = LoginItem.isEnabled
        isLoading = false
    }

    // MARK: - Persistence

    private func load() {
        isLoading = true
        defer { isLoading = false }

        guard let data = try? Data(contentsOf: Paths.settingsFile) else {
            Log.info("Nessun settings.json, uso i default")
            return
        }
        guard let decoded = try? JSONDecoder().decode(SettingsData.self, from: data) else {
            Log.error("settings.json illeggibile, uso i default")
            return
        }

        if let v = decoded.refreshIntervalMinutes { refreshIntervalMinutes = v }
        if let v = decoded.warnThreshold { warnThreshold = v }
        if let v = decoded.dangerThreshold { dangerThreshold = v }
        if let v = decoded.notificationsEnabled { notificationsEnabled = v }
        if let v = decoded.notifyOnWaitingInput { notifyOnWaitingInput = v }
        if let v = decoded.notificationSound { notificationSound = v }
        if let v = decoded.notifyOnDone { notifyOnDone = v }
        if let v = decoded.notifyOnFailure { notifyOnFailure = v }
        if let v = decoded.glowEnabled { glowEnabled = v }
        if let v = decoded.clearAlertsOnFocus { clearAlertsOnFocus = v }
        if let v = decoded.glowStyles { glowStyles = v }
        if let v = decoded.debugLoggingEnabled { debugLoggingEnabled = v }
        if let v = decoded.panelOpacity { panelOpacity = v }
        if let v = decoded.displayMode { displayMode = v }
        if let v = decoded.theme { theme = v }
        if let v = decoded.notchExpandOnHover { notchExpandOnHover = v }
        if let v = decoded.notchShowsControls { notchShowsControls = v }
        if let v = decoded.notchScale { notchScale = v }
        if let v = decoded.notchWidth ?? decoded.virtualNotchWidth { notchWidth = v }
        if let v = decoded.notchHeight ?? decoded.virtualNotchHeight { notchHeight = v }
        if let v = decoded.usePerScreenNotchSize { usePerScreenNotchSize = v }
        if let v = decoded.notchSizeByScreen { notchSizeByScreen = v }
        if let v = decoded.notchScreenSelection { notchScreenSelection = v }
        if let v = decoded.notchScreenIDs { notchScreenIDs = v }
        if let v = decoded.panelVisible { panelVisible = v }
        if let v = decoded.panelCollapsed { panelCollapsed = v }
        if let v = decoded.panelAnchor { panelAnchor = v }
        if let x = decoded.panelTopLeftX, let y = decoded.panelTopLeftY {
            panelTopLeft = CGPoint(x: x, y: y)
        }
        if let v = decoded.projectsRefreshMinutes { projectsRefreshMinutes = v }
        if let v = decoded.showPercentageInMenuBar { showPercentageInMenuBar = v }
        if let v = decoded.showMenuBarIcon { showMenuBarIcon = v }
        if let v = decoded.launchAtLogin { launchAtLogin = v }
        if let v = decoded.hasCompletedOnboarding { hasCompletedOnboarding = v }
        if let v = decoded.decisionWaitSeconds { decisionWaitSeconds = v }

        Log.info("Settings caricati da \(Paths.settingsFile.path)")
    }

    /// Coalesce bursts of `didSet` (e.g. a slider being dragged) into one write.
    private func schedulePersist() {
        guard !isLoading else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    func persistNow() {
        Paths.ensureDirectories()
        let data = SettingsData(
            refreshIntervalMinutes: refreshIntervalMinutes,
            warnThreshold: warnThreshold,
            dangerThreshold: dangerThreshold,
            notificationsEnabled: notificationsEnabled,
            notifyOnWaitingInput: notifyOnWaitingInput,
            notificationSound: notificationSound,
            notifyOnDone: notifyOnDone,
            notifyOnFailure: notifyOnFailure,
            glowEnabled: glowEnabled,
            clearAlertsOnFocus: clearAlertsOnFocus,
            glowStyles: glowStyles,
            debugLoggingEnabled: debugLoggingEnabled,
            panelOpacity: panelOpacity,
            panelVisible: panelVisible,
            panelCollapsed: panelCollapsed,
            panelAnchor: panelAnchor,
            displayMode: displayMode,
            theme: theme,
            notchExpandOnHover: notchExpandOnHover,
            notchShowsControls: notchShowsControls,
            notchScale: notchScale,
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            usePerScreenNotchSize: usePerScreenNotchSize,
            notchSizeByScreen: notchSizeByScreen,
            virtualNotchWidth: nil,
            virtualNotchHeight: nil,
            notchScreenSelection: notchScreenSelection,
            notchScreenIDs: notchScreenIDs,
            panelTopLeftX: panelTopLeft.map { Double($0.x) },
            panelTopLeftY: panelTopLeft.map { Double($0.y) },
            projectsRefreshMinutes: projectsRefreshMinutes,
            showPercentageInMenuBar: showPercentageInMenuBar,
            showMenuBarIcon: showMenuBarIcon,
            launchAtLogin: launchAtLogin,
            hasCompletedOnboarding: hasCompletedOnboarding,
            decisionWaitSeconds: decisionWaitSeconds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let encoded = try? encoder.encode(data) else { return }
        do {
            try encoded.write(to: Paths.settingsFile, options: .atomic)
        } catch {
            Log.error("Salvataggio settings fallito: \(error.localizedDescription)")
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
