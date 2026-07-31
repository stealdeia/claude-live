import AppKit
import Combine

/// The menu bar item: shows the 5h session percentage and hosts the app's menu.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let monitor: UsageMonitor
    private let projects: ProjectsMonitor
    private let status: ClaudeStatusStore
    private let settings: Settings

    private let onTogglePanel: () -> Void
    private let onOpenSettings: () -> Void
    private let onInstallHooks: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onShowOnboarding: () -> Void

    private var cancellables: Set<AnyCancellable> = []

    init(
        monitor: UsageMonitor,
        projects: ProjectsMonitor,
        status: ClaudeStatusStore,
        settings: Settings,
        onTogglePanel: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onInstallHooks: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onShowOnboarding: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.projects = projects
        self.status = status
        self.settings = settings
        self.onTogglePanel = onTogglePanel
        self.onOpenSettings = onOpenSettings
        self.onInstallHooks = onInstallHooks
        self.onCheckForUpdates = onCheckForUpdates
        self.onShowOnboarding = onShowOnboarding
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        configureButton()
        rebuildMenu()

        // Redraw the title whenever the data or the relevant settings change.
        monitor.$snapshot
            .combineLatest(monitor.$state)
            .sink { [weak self] _, _ in
                Task { @MainActor in
                    self?.updateTitle()
                    self?.rebuildMenu()
                }
            }
            .store(in: &cancellables)

        status.$statusesByPath
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateTitle()
                    self?.rebuildMenu()
                }
            }
            .store(in: &cancellables)

        projects.$projects
            .sink { [weak self] _ in
                Task { @MainActor in self?.rebuildMenu() }
            }
            .store(in: &cancellables)

        settings.$showPercentageInMenuBar
            .combineLatest(settings.$warnThreshold, settings.$dangerThreshold)
            .sink { [weak self] _, _, _ in
                Task { @MainActor in self?.updateTitle() }
            }
            .store(in: &cancellables)

        updateTitle()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "sparkle",
            accessibilityDescription: "Claude Live"
        )
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    }

    // MARK: - Title

    private func updateTitle() {
        guard let button = statusItem.button else { return }

        guard settings.showPercentageInMenuBar else {
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = tooltip()
            return
        }

        let text: String
        var color = NSColor.labelColor

        if case .unavailable = monitor.state {
            // No credentials at all — a dash plus an explanatory tooltip.
            text = " –"
            color = .systemOrange
        } else if let percent = monitor.snapshot?.headlinePercent {
            text = " \(Int(percent.rounded()))%"
            switch UsageLevel.level(
                for: percent / 100,
                warn: settings.warnThreshold,
                danger: settings.dangerThreshold
            ) {
            case .normal: color = .labelColor
            case .warning: color = .systemOrange
            case .danger: color = .systemRed
            }
            // A stale reading is dimmed rather than hidden.
            if case .stale = monitor.state { color = color.withAlphaComponent(0.55) }
        } else if case .stale = monitor.state {
            text = " –"
            color = .systemOrange
        } else {
            text = " …"
            color = .secondaryLabelColor
        }

        let title = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: color
            ]
        )

        // An orange dot whenever Claude Code is waiting for the user somewhere:
        // the whole point of the app is not missing those.
        let waiting = status.waitingCount
        if waiting > 0 {
            title.append(NSAttributedString(
                string: waiting > 1 ? " ●\(waiting)" : " ●",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.systemOrange
                ]
            ))
        }

        button.attributedTitle = title
        button.toolTip = tooltip()
    }

    private func tooltip() -> String {
        var lines: [String] = ["Claude Live"]

        if let snapshot = monitor.snapshot {
            if let five = snapshot.fiveHour {
                var line = "Sessione 5h: \(Format.percent(five.utilization))"
                if let resetAt = five.resetAt { line += " · reset in \(Format.countdown(to: resetAt))" }
                lines.append(line)
            }
            if let seven = snapshot.sevenDay {
                var line = "Settimana 7g: \(Format.percent(seven.utilization))"
                if let resetAt = seven.resetAt { line += " · reset in \(Format.countdown(to: resetAt))" }
                lines.append(line)
            }
            lines.append("Aggiornato \(Format.age(since: snapshot.fetchedAt))")
        }

        switch monitor.state {
        case .unavailable(let message): lines.append(message)
        case .stale(let reason): lines.append(reason.message)
        default: break
        }

        let waiting = status.statusesByPath.values.filter { $0.state == .waitingInput }
        if !waiting.isEmpty {
            let names = waiting
                .map { ($0.projectPath as NSString).lastPathComponent }
                .sorted()
            lines.append("Claude attende input: \(names.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Read-only summary at the top.
        if let snapshot = monitor.snapshot {
            if let five = snapshot.fiveHour {
                menu.addItem(summaryItem(title: "Sessione 5h", window: five))
            }
            if let seven = snapshot.sevenDay {
                menu.addItem(summaryItem(title: "Settimana 7g", window: seven))
            }
            let stamp = NSMenuItem(title: "Aggiornato \(Format.age(since: snapshot.fetchedAt))", action: nil, keyEquivalent: "")
            stamp.isEnabled = false
            menu.addItem(stamp)
        } else {
            let empty = NSMenuItem(title: "Nessun dato di utilizzo", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        if case .unavailable(let message) = monitor.state {
            menu.addItem(.separator())
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // Projects, so switching is possible even with the panel hidden.
        if !projects.projects.isEmpty {
            menu.addItem(.separator())
            let heading = NSMenuItem(title: "Progetti VS Code", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)

            for project in projects.projects {
                menu.addItem(projectItem(project))
            }
            menu.addItem(action(title: projects.isRefreshing ? "Aggiornamento…" : "Aggiorna progetti",
                                key: "", selector: #selector(refreshProjects)))
        }

        if !status.hooksInstalled {
            menu.addItem(.separator())
            menu.addItem(action(title: "Installa hook Claude Code…", key: "", selector: #selector(installHooks)))
        }

        menu.addItem(.separator())
        // Only offered on a Mac that has a notch to attach to.
        if NotchGeometry.isAvailable {
            menu.addItem(action(
                title: settings.displayMode == .notch ? "Passa al pannello flottante" : "Passa al notch",
                key: "",
                selector: #selector(toggleDisplayMode)
            ))
        }
        menu.addItem(action(title: "Aggiorna ora", key: "r", selector: #selector(refreshNow)))
        menu.addItem(action(title: settings.panelVisible ? "Nascondi pannello" : "Mostra pannello",
                            key: "p", selector: #selector(togglePanel)))
        menu.addItem(action(title: settings.panelCollapsed ? "Espandi pannello" : "Comprimi pannello",
                            key: "", selector: #selector(toggleCollapsed)))

        // Anchor submenu.
        let anchorItem = NSMenuItem(title: "Posizione pannello", action: nil, keyEquivalent: "")
        let anchorMenu = NSMenu()
        for anchor in PanelAnchor.allCases {
            let item = NSMenuItem(title: anchor.label, action: #selector(selectAnchor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = anchor.rawValue
            item.state = settings.panelAnchor == anchor ? .on : .off
            // "Free" is a result of dragging, not something to pick from a menu.
            item.isEnabled = anchor != .free
            anchorMenu.addItem(item)
        }
        anchorItem.submenu = anchorMenu
        menu.addItem(anchorItem)

        menu.addItem(.separator())
        menu.addItem(action(title: "Impostazioni…", key: ",", selector: #selector(openSettings)))
        menu.addItem(action(title: "Configurazione guidata…", key: "", selector: #selector(showOnboarding)))
        menu.addItem(action(title: "Cerca aggiornamenti…", key: "", selector: #selector(checkForUpdates)))
        menu.addItem(action(title: "Apri cartella dati", key: "", selector: #selector(openSupportFolder)))
        if settings.debugLoggingEnabled {
            menu.addItem(action(title: "Apri log", key: "", selector: #selector(openLog)))
            menu.addItem(action(title: "Copia header rate-limit", key: "", selector: #selector(copyHeaders)))
        }

        menu.addItem(.separator())
        let version = NSMenuItem(title: "Versione \(UpdateController.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(action(title: "Esci da Claude Live", key: "q", selector: #selector(quit)))

        statusItem.menu = menu
    }

    private func summaryItem(title: String, window: UsageWindow) -> NSMenuItem {
        var text = "\(title): \(Format.percent(window.utilization))"
        if let resetAt = window.resetAt {
            text += "  ·  reset in \(Format.countdown(to: resetAt))"
        }
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A project row: state marker, name, and the awaited request as a suffix.
    private func projectItem(_ project: VSCodeProject) -> NSMenuItem {
        let projectStatus = status.status(for: project)

        let marker: String
        switch projectStatus?.state {
        case .working: marker = "▶︎"
        case .waitingInput: marker = "●"
        case .error: marker = "✕"
        case .idle: marker = "·"
        case .unknown: marker = "?"
        case .none: marker = " "
        }

        var title = "\(marker)  \(project.name)"
        if let badge = projectStatus?.badge {
            title += "  — \(badge)"
        }

        let item = NSMenuItem(title: title, action: #selector(focusProject(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = project.id
        item.isEnabled = true
        item.toolTip = project.displayPath

        // Colour only the states that need attention; the rest stay default so
        // the menu doesn't look like a Christmas tree.
        let color: NSColor? = switch projectStatus?.state {
        case .waitingInput: .systemOrange
        case .error: .systemRed
        default: nil
        }
        if let color {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: color
                ]
            )
        }
        return item
    }

    private func action(title: String, key: String, selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        return item
    }

    // MARK: - Menu actions

    @objc private func refreshNow() {
        Task { await monitor.refresh(reason: "menu") }
    }

    @objc private func togglePanel() {
        onTogglePanel()
        rebuildMenu()
    }

    @objc private func toggleCollapsed() {
        settings.panelCollapsed.toggle()
        rebuildMenu()
    }

    @objc private func selectAnchor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let anchor = PanelAnchor(rawValue: raw) else { return }
        settings.panelAnchor = anchor
        rebuildMenu()
    }

    @objc private func toggleDisplayMode() {
        settings.displayMode = settings.displayMode == .notch ? .floating : .notch
        rebuildMenu()
    }

    @objc private func refreshProjects() {
        projects.refresh(reason: "menu")
    }

    @objc private func focusProject(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let project = projects.projects.first(where: { $0.id == id }) else { return }
        projects.focus(project)
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates()
    }

    @objc private func showOnboarding() {
        onShowOnboarding()
    }

    @objc private func installHooks() {
        onInstallHooks()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func openSupportFolder() {
        Paths.ensureDirectories()
        NSWorkspace.shared.open(Paths.supportDirectory)
    }

    @objc private func openLog() {
        Paths.ensureDirectories()
        if !FileManager.default.fileExists(atPath: Paths.logFile.path) {
            try? Data().write(to: Paths.logFile)
        }
        NSWorkspace.shared.open(Paths.logFile)
    }

    @objc private func copyHeaders() {
        let text = monitor.rawHeaders
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.isEmpty ? "(nessun header)" : text, forType: .string)
        Log.info("Header rate-limit copiati negli appunti")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
