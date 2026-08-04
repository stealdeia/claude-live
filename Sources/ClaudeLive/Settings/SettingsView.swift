import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var status: ClaudeStatusStore
    @ObservedObject var updates: UpdateController
    let onInstallHooks: () -> Void
    let onShowOnboarding: () -> Void

    /// Owned here rather than injected: it only exists while this window is open.
    @StateObject private var screens = ScreenCatalog()

    var body: some View {
        // No explicit width or `fixedSize` here on purpose: the window decides
        // the size and the form fills it. Doing it the other way round made the
        // content wider than the window and clipped both edges.
        Form {
            surfaceSection
            updateSection
            thresholdsSection
            hooksSection
            if settings.displayMode == .floating { panelSection }
            diagnosticsSection
            aboutSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    private var updateSection: some View {
        Section("Aggiornamento") {
            LabeledContent("Intervallo") {
                HStack(spacing: 8) {
                    Text("\(Int(settings.refreshIntervalMinutes)) min")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("Intervallo", value: $settings.refreshIntervalMinutes, in: 1...60, step: 1)
                        .labelsHidden()
                }
            }

            LabeledContent("Progetti VS Code") {
                HStack(spacing: 8) {
                    Text(settings.projectsRefreshMinutes == 0
                         ? "solo su eventi"
                         : "ogni \(Int(settings.projectsRefreshMinutes)) min")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("Progetti", value: $settings.projectsRefreshMinutes, in: 0...60, step: 1)
                        .labelsHidden()
                }
            }

            Text("La lista progetti si aggiorna quando apri o chiudi una finestra VS Code. Un refresh periodico è sconsigliato: ogni lettura esegue «code --status», che fa comparire per un istante una seconda icona di VS Code nel Dock.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let next = monitor.nextRefreshAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LabeledContent("Prossimo aggiornamento") {
                        Text("fra \(Format.countdown(to: next, now: context.date))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var thresholdsSection: some View {
        Section("Soglie") {
            thresholdRow(
                title: "Attenzione (giallo)",
                value: $settings.warnThreshold,
                range: 0.30...0.95,
                tint: PanelTheme.color(for: .warning)
            )
            thresholdRow(
                title: "Critico (rosso)",
                value: $settings.dangerThreshold,
                range: 0.50...0.99,
                tint: PanelTheme.color(for: .danger)
            )
            Toggle("Notifiche di macOS al superamento", isOn: $settings.notificationsEnabled)
        }
    }

    private var hooksSection: some View {
        Section("Stato Claude Code") {
            LabeledContent("Hook") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.hooksInstalled
                              ? PanelTheme.color(for: .normal)
                              : PanelTheme.color(for: .warning))
                        .frame(width: 8, height: 8)
                    Text(status.hooksInstalled ? "installati" : "non installati")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Notifica quando Claude attende input", isOn: $settings.notifyOnWaitingInput)

            LabeledContent("Rispondi dal pannello") {
                HStack(spacing: 8) {
                    Text(settings.decisionWaitSeconds == 0
                         ? "disattivato"
                         : "attendi \(Int(settings.decisionWaitSeconds))s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("Attesa", value: $settings.decisionWaitSeconds, in: 0...60, step: 1)
                        .labelsHidden()
                }
            }

            Text("Quando Claude chiede un permesso, l'hook attende questo tempo una tua risposta dal pannello. In quei secondi il terminale resta silenzioso: se non rispondi, la richiesta compare lì come sempre. Con 0 il pannello mostra le richieste ma non permette di rispondere.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(status.hooksInstalled ? "Reinstalla hook…" : "Installa hook…",
                       action: onInstallHooks)
                Spacer()
                Button("Apri cartella di stato") {
                    Paths.ensureStatusDirectory()
                    NSWorkspace.shared.open(Paths.statusDirectory)
                }
            }

            if !status.statusesByPath.isEmpty {
                LabeledContent("Sessioni attive") {
                    Text("\(status.statusesByPath.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Text("Gli hook scrivono in ~/.claude-hub/status/. Puoi installarli anche da terminale con Resources/install-claude-hooks.py (supporta --dry-run e --uninstall).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var surfaceSection: some View {
        Section("Superficie") {
            Picker("Modalità", selection: $settings.displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            if settings.displayMode == .notch {
                screenPicker

                LabeledContent("Dimensione contatori") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.notchScale, in: 0.9...1.5, step: 0.05)
                            .frame(minWidth: 120)
                        Text(String(format: "%.0f%%", settings.notchScale * 100))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }

                notchSizeControls

                Toggle("Espandi al passaggio del mouse", isOn: $settings.notchExpandOnHover)
                Text("Nel notch l'interfaccia è sempre nera, per allinearsi al ritaglio fisico dello schermo. Sugli schermi che non hanno un notch viene disegnato, al centro del bordo superiore.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Tema", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
            }
        }
    }

    private var panelSection: some View {
        Section("Pannello flottante") {
            Picker("Ancoraggio", selection: $settings.panelAnchor) {
                ForEach(PanelAnchor.allCases) { anchor in
                    Text(anchor.label).tag(anchor)
                }
            }

            LabeledContent("Opacità") {
                HStack(spacing: 10) {
                    Slider(value: $settings.panelOpacity, in: 0.35...1.0)
                        .frame(minWidth: 120)
                    Text(Format.percent(settings.panelOpacity))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }

            Toggle("Pannello compresso", isOn: $settings.panelCollapsed)
            Toggle("Mostra percentuale nella barra dei menu", isOn: $settings.showPercentageInMenuBar)
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostica") {
            if let snapshot = monitor.snapshot {
                LabeledContent("Ultima lettura") {
                    Text("\(Format.age(since: snapshot.fetchedAt)) · HTTP \(snapshot.httpStatus)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let plan = monitor.snapshot?.subscriptionType {
                LabeledContent("Piano") {
                    Text(plan).foregroundStyle(.secondary)
                }
            }

            Toggle("Log di debug su file", isOn: $settings.debugLoggingEnabled)

            if settings.debugLoggingEnabled {
                Text(Paths.logFile.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            HStack {
                Button("Aggiorna ora") {
                    Task { await monitor.refresh(reason: "impostazioni") }
                }
                Button("Copia header") {
                    copyHeaders()
                }
                .disabled(monitor.rawHeaders.isEmpty)

                Spacer()

                Button("Apri cartella dati") {
                    Paths.ensureDirectories()
                    NSWorkspace.shared.open(Paths.supportDirectory)
                }
            }
        }
    }

    private var aboutSection: some View {
        Section("Informazioni") {
            LabeledContent("Versione") {
                Text(UpdateController.currentVersion)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Ultimo controllo aggiornamenti") {
                Text(updates.lastCheckDescription)
                    .foregroundStyle(.secondary)
            }
            Toggle("Controlla automaticamente gli aggiornamenti", isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: { updates.automaticallyChecksForUpdates = $0 }
            ))
            HStack {
                Button(updates.isCheckInProgress ? "Controllo…" : "Cerca aggiornamenti") {
                    updates.checkForUpdates()
                }
                .disabled(updates.isCheckInProgress)
                Spacer()
                Button("Configurazione guidata…", action: onShowOnboarding)
            }
        }
    }

    /// Size of the notch bar's middle section.
    ///
    /// The caption earns its place: on a screen with a real cutout these are
    /// *minimums*, so moving a slider below the hardware size looks like nothing
    /// happening. Saying so is cheaper than the user concluding it is broken.
    @ViewBuilder
    private var notchSizeControls: some View {
        LabeledContent("Larghezza notch") {
            HStack(spacing: 10) {
                Slider(value: $settings.notchWidth, in: NotchGeometry.widthRange)
                    .frame(minWidth: 100)
                Text(sizeLabel(requested: settings.notchWidth, floor: hardwareFloor?.width))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .trailing)
            }
        }

        LabeledContent("Altezza notch") {
            HStack(spacing: 10) {
                Slider(value: $settings.notchHeight, in: NotchGeometry.heightRange)
                    .frame(minWidth: 100)
                Text(sizeLabel(requested: settings.notchHeight, floor: hardwareFloor?.height))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .trailing)
            }
        }

        HStack {
            Text(notchSizeHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Ripristina") {
                settings.notchWidth = NotchGeometry.defaultNotchSize.width
                settings.notchHeight = NotchGeometry.defaultNotchSize.height
            }
            .controlSize(.small)
        }
    }

    /// Shows what the value actually becomes when the hardware raises it, e.g.
    /// `170 → 185pt`. Without this the slider looks stuck for its whole lower half.
    private func sizeLabel(requested: Double, floor: CGFloat?) -> String {
        guard let floor, Double(floor) > requested + 0.5 else { return "\(Int(requested)) pt" }
        return "\(Int(requested)) → \(Int(floor)) pt"
    }

    /// The cutout that raises the requested size, if one of the screens getting a
    /// notch actually has a cutout.
    private var hardwareFloor: CGSize? {
        guard let cutout = NotchGeometry.physicalCutout(),
              let screen = NotchGeometry.screenWithPhysicalNotch()
        else { return nil }

        switch settings.notchScreenSelection {
        // Automatic prefers the screen with the cutout, so it is always the target.
        case .automatic, .all:
            return cutout.size
        case .chosen:
            let id = ScreenIdentity.identifier(for: screen)
            return settings.notchScreenIDs.contains(id) ? cutout.size : nil
        }
    }

    /// Spells out the minimum imposed by the hardware, with the actual numbers of
    /// the connected screen — a generic "depends on your display" would leave the
    /// user guessing why a slider seems stuck.
    private var notchSizeHint: String {
        let base = "La larghezza è quella del tratto centrale: la barra completa aggiunge i due contatori."
        guard let floor = hardwareFloor else { return base }
        return base + " Il notch fisico di questo Mac è \(Int(floor.width))×\(Int(floor.height))pt e fa da minimo: sotto quelle misure i contatori finirebbero dentro il ritaglio, dove non si vede nulla."
    }

    /// Choice of displays, plus the tick list when the choice is explicit.
    ///
    /// The list comes from `ScreenCatalog` rather than a snapshot taken when the
    /// window opened: this window is often open exactly while a monitor is being
    /// plugged in, and offering a display that no longer exists is worse than
    /// offering none.
    @ViewBuilder
    private var screenPicker: some View {
        Picker("Schermi", selection: $settings.notchScreenSelection) {
            ForEach(NotchScreenSelection.allCases) { selection in
                Text(selection.label).tag(selection)
            }
        }

        if settings.notchScreenSelection == .chosen {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(screens.screens) { screen in
                    Toggle(isOn: screenBinding(screen.id)) {
                        HStack(spacing: 6) {
                            Text(screen.name)
                            if screen.hasPhysicalNotch {
                                Text("notch fisico")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            }
                            Text("\(Int(screen.pixelSize.width))×\(Int(screen.pixelSize.height))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
            }

            if settings.notchScreenIDs.isEmpty {
                Text("Nessuno schermo selezionato: il notch resta su quello automatico.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Toggles one display in the chosen list. Identifiers of monitors that are
    /// currently disconnected are left untouched, so unplugging and replugging a
    /// monitor restores its notch without reconfiguring anything.
    private func screenBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.notchScreenIDs.contains(id) },
            set: { isOn in
                var ids = settings.notchScreenIDs
                if isOn {
                    guard !ids.contains(id) else { return }
                    ids.append(id)
                } else {
                    ids.removeAll { $0 == id }
                }
                settings.notchScreenIDs = ids
            }
        )
    }

    // MARK: - Pieces

    /// Label on its own line above the slider: at this window width a single
    /// row of label + slider + value squeezes the slider down to nothing.
    private func thresholdRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(title)
                Spacer()
                Text(Format.percent(value.wrappedValue))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func copyHeaders() {
        let text = monitor.rawHeaders
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
