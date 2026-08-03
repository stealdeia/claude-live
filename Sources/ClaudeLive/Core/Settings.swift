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
    var debugLoggingEnabled: Bool?
    var panelOpacity: Double?
    var panelVisible: Bool?
    var panelCollapsed: Bool?
    var panelAnchor: PanelAnchor?
    var displayMode: DisplayMode?
    var theme: AppTheme?
    var notchExpandOnHover: Bool?
    var notchScale: Double?
    var panelTopLeftX: Double?
    var panelTopLeftY: Double?
    var projectsRefreshMinutes: Double?
    var showPercentageInMenuBar: Bool?
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
        if let v = decoded.debugLoggingEnabled { debugLoggingEnabled = v }
        if let v = decoded.panelOpacity { panelOpacity = v }
        if let v = decoded.displayMode { displayMode = v }
        if let v = decoded.theme { theme = v }
        if let v = decoded.notchExpandOnHover { notchExpandOnHover = v }
        if let v = decoded.notchScale { notchScale = v }
        if let v = decoded.panelVisible { panelVisible = v }
        if let v = decoded.panelCollapsed { panelCollapsed = v }
        if let v = decoded.panelAnchor { panelAnchor = v }
        if let x = decoded.panelTopLeftX, let y = decoded.panelTopLeftY {
            panelTopLeft = CGPoint(x: x, y: y)
        }
        if let v = decoded.projectsRefreshMinutes { projectsRefreshMinutes = v }
        if let v = decoded.showPercentageInMenuBar { showPercentageInMenuBar = v }
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
            debugLoggingEnabled: debugLoggingEnabled,
            panelOpacity: panelOpacity,
            panelVisible: panelVisible,
            panelCollapsed: panelCollapsed,
            panelAnchor: panelAnchor,
            displayMode: displayMode,
            theme: theme,
            notchExpandOnHover: notchExpandOnHover,
            notchScale: notchScale,
            panelTopLeftX: panelTopLeft.map { Double($0.x) },
            panelTopLeftY: panelTopLeft.map { Double($0.y) },
            projectsRefreshMinutes: projectsRefreshMinutes,
            showPercentageInMenuBar: showPercentageInMenuBar,
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
