import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: Settings
    /// Set by the menu bar to open straight onto the screens sheet.
    @ObservedObject var ui: SettingsUIState
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var status: ClaudeStatusStore
    @ObservedObject var updates: UpdateController
    let onInstallHooks: () -> Void
    let onShowOnboarding: () -> Void

    @State private var showNotchScreens = false

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
        .sheet(isPresented: $showNotchScreens) {
            NotchScreensView(settings: settings) { showNotchScreens = false }
        }
        // The menu bar can ask for this sheet directly; the flag is consumed so
        // reopening Settings later does not open it again.
        .onChange(of: ui.requestsNotchScreens) { _, requested in
            guard requested else { return }
            showNotchScreens = true
            ui.requestsNotchScreens = false
        }
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
                LabeledContent("Scelta schermi e dimensioni notch") {
                    Button("Configura…") { showNotchScreens = true }
                }
                Text(screensSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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

    /// One line describing what is configured, so the button is not a black box.
    private var screensSummary: String {
        let active = NotchGeometry.geometries(
            selection: settings.notchScreenSelection,
            chosenIDs: settings.notchScreenIDs,
            notchSize: { settings.notchSize(forScreen: $0) }
        )
        let where_ = switch settings.notchScreenSelection {
        case .automatic: "schermo automatico"
        case .all: "tutti gli schermi"
        case .chosen: active.count == 1 ? "uno schermo scelto" : "\(active.count) schermi scelti"
        }
        let sizes = settings.usePerScreenNotchSize
            ? "dimensioni separate per schermo"
            : "\(Int(settings.notchWidth))×\(Int(settings.notchHeight))pt su tutti"
        return "\(where_.prefix(1).uppercased() + where_.dropFirst()), \(sizes)."
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
