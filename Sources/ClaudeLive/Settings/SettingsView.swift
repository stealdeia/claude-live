import SwiftUI
import AppKit
import ClaudeLiveKit

struct SettingsView: View {
    @ObservedObject var settings: Settings
    /// Set by the menu bar to open straight onto the screens sheet.
    @ObservedObject var ui: SettingsUIState
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var projects: ProjectsMonitor
    @ObservedObject var status: ClaudeStatusStore
    @ObservedObject var remote: RemotePublisher
    @ObservedObject var updates: UpdateController
    let onInstallHooks: () -> Void
    let onShowOnboarding: () -> Void
    let onTogglePanelVisibility: () -> Void
    let onPreviewGlow: (NotchGlowPalette) -> Void
    let onQuit: () -> Void

    @State private var showNotchScreens = false
    @State private var tab: Tab = .appearance

    /// Le sezioni della finestra, nell'ordine della barra laterale.
    ///
    /// Erano undici sezioni in un'unica lista da scorrere, e trovarne una voleva
    /// dire ricordarsi a che altezza stava. Raggruppate per la domanda a cui
    /// rispondono, non per l'ordine in cui sono state scritte.
    private enum Tab: String, CaseIterable, Identifiable, Hashable {
        case appearance, glow, notifications, claudeCode, phone, refresh, diagnostics, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appearance: return "Aspetto"
            case .glow: return "Segnale luminoso"
            case .notifications: return "Notifiche"
            case .claudeCode: return "Claude Code"
            case .phone: return "iPhone"
            case .refresh: return "Frequenza"
            case .diagnostics: return "Diagnostica"
            case .about: return "Informazioni"
            }
        }

        var icon: String {
            switch self {
            case .appearance: return "paintbrush"
            case .glow: return "light.beacon.max"
            case .notifications: return "bell"
            case .claudeCode: return "terminal"
            case .phone: return "iphone"
            case .refresh: return "timer"
            case .diagnostics: return "stethoscope"
            case .about: return "info.circle"
            }
        }
    }

    /// Il segnale luminoso esiste solo sul notch, quindi la sua voce non c'è
    /// quando il notch non c'è: una sezione vuota è una domanda senza risposta.
    private var tabs: [Tab] {
        Tab.allCases.filter { $0 != .glow || settings.displayMode == .notch }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $tab) {
                ForEach(tabs) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 176, ideal: 188, max: 230)
        } detail: {
            // No explicit width or `fixedSize` here on purpose: the window decides
            // the size and the form fills it. Doing it the other way round made the
            // content wider than the window and clipped both edges.
            Form {
                sections(for: tab)
            }
            .formStyle(.grouped)
            .navigationTitle(tab.title)
        }
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

    @ViewBuilder
    private func sections(for tab: Tab) -> some View {
        switch tab {
        case .appearance:
            surfaceSection
            if settings.displayMode == .notch { themeSection }
            menuBarSection
            if settings.displayMode == .floating { panelSection }
        case .glow:
            glowSection
        case .notifications:
            notificationsSection
            thresholdsSection
        case .claudeCode:
            hooksSection
        case .phone:
            CompanionSettingsView(settings: settings, remote: remote)
        case .refresh:
            updateSection
        case .diagnostics:
            diagnosticsSection
        case .about:
            aboutSection
        }
    }

    // MARK: - Tema del pannello

    private var themeSection: some View {
        Section("Tema") {
            LabeledContent("Colore del pannello") {
                HStack(spacing: 8) {
                    ForEach(ColorTheme.panelChoices) { theme in
                        let chosen = settings.panelThemeID == theme.id
                        Button { settings.panelThemeID = theme.id } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [.black, theme.bloom, theme.deep],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ))
                                .frame(width: 36, height: 24)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(
                                            chosen ? Color.accentColor : Color.primary.opacity(0.18),
                                            lineWidth: chosen ? 2 : 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .help(theme.name)
                        .accessibilityLabel(theme.name)
                    }
                }
            }

            // L'anteprima, larga come merita: è su un'altezza vera che il
            // gradiente si vede, e cliccare un quadratino da un centimetro
            // significava scegliere alla cieca.
            VStack(spacing: 8) {
                NotchThemePreview(theme: chosenTheme)
                Text(chosenTheme.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .animation(.easeOut(duration: 0.18), value: settings.panelThemeID)

            Text("Il bordo superiore resta nero in ogni tema: è quello che fa sparire il pannello nel ritaglio del MacBook. Il colore arriva scendendo, quindi da chiuso non si vede.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chosenTheme: ColorTheme {
        ColorTheme.panelChoices.first { $0.id == settings.panelThemeID } ?? ColorTheme.midnight
    }

    // MARK: - Sections

    private var updateSection: some View {
        Section("Ogni quanto rileggere") {
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

            Text("Quando il token di Claude Code scade (di solito dopo 8 ore, quindi ogni notte) l'app aspetta che sia Claude Code a rinnovarlo e se ne accorge entro 30 secondi: basta usare Claude Code e i dati ripartono da soli. L'app non rinnova mai il token per conto suo — farlo scollega Claude Code dall'account.")
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
        }
    }

    /// Every notification the app can post, and how it sounds, in one place.
    ///
    /// «Claude attende input» used to live under *Stato Claude Code* and the
    /// threshold banners under *Soglie*: two switches for the same thing, in two
    /// sections, neither of which was about notifications.
    private var notificationsSection: some View {
        Section("Notifiche") {
            Toggle("Quando Claude chiede qualcosa", isOn: $settings.notifyOnWaitingInput)
            Toggle("Quando Claude ha finito", isOn: $settings.notifyOnDone)
            Toggle("Quando Claude si interrompe", isOn: $settings.notifyOnFailure)
            Toggle("Al superamento delle soglie", isOn: $settings.notificationsEnabled)

            Picker("Suono", selection: $settings.notificationSound) {
                Text(NotificationSound.label(for: NotificationSound.systemDefault))
                    .tag(NotificationSound.systemDefault)
                Divider()
                ForEach(NotificationSound.available, id: \.self) { name in
                    Text(name).tag(name)
                }
            }

            HStack {
                Text("Il suono vale per tutte le notifiche dell'app. «Prova» manda una notifica vera: quel che senti è quel che sentirai.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Prova") {
                    NotificationSound.preview(settings.notificationSound)
                }
            }

        }
    }

    /// The luminous strip: one colour per kind of event, because the point of
    /// colouring it is telling them apart from across the room.
    private var glowSection: some View {
        Section("Segnale luminoso") {
            Toggle("Striscia luminosa attorno al notch", isOn: $settings.glowEnabled)

            ForEach(ClaudeAlertKind.allCases) { kind in
                glowRow(for: kind)
                    .disabled(!settings.glowEnabled)
            }

            Text("Si accende quando Claude chiede qualcosa, quando ha finito e quando si interrompe, e nella lista progetti si illumina la riga del progetto — e la chat esatta, se sono più di una — con lo stesso colore e la stessa pulsazione. Non compare per il superamento delle soglie: quello non è un evento di un progetto e non ci sarebbe niente da cliccare, restano la notifica e il colore degli anelli.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Spegni il segnale anche portando in primo piano il progetto",
                   isOn: $settings.clearAlertsOnFocus)

            if settings.clearAlertsOnFocus {
                if FrontProjectWatcher.isTrustedForTitles {
                    Text("Riconosce il progetto dalla finestra dell'editor in primo piano, anche passando da una finestra all'altra.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Stated rather than demanded: the app works without it, just
                    // less precisely, and it is the only permission it ever asks for.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Per sapere **quale** finestra hai davanti serve il permesso di Accessibilità: macOS protegge i titoli delle finestre. Senza permesso il segnale si spegne comunque quando porti l'editor in primo piano, ma solo se c'è un unico avviso in sospeso.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Concedi il permesso…") {
                                FrontProjectWatcher.requestTrust()
                            }
                            Button("Apri Impostazioni di Sistema") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private func glowRow(for kind: ClaudeAlertKind) -> some View {
        let style = settings.glowStyle(for: kind)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(kind.label)
                    .font(.callout)
                Spacer(minLength: 6)
                Picker("", selection: Binding(
                    get: { style.mode },
                    set: { settings.setGlowStyle(GlowStyle(mode: $0, primary: style.primary, secondary: style.secondary), for: kind) }
                )) {
                    ForEach(GlowStyle.Mode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            HStack(spacing: 10) {
                if style.mode != .rainbow {
                    ColorPicker("Centro", selection: Binding(
                        get: { style.primary.color },
                        set: { settings.setGlowStyle(GlowStyle(mode: style.mode, primary: GlowRGB($0), secondary: style.secondary), for: kind) }
                    ))
                    .labelsHidden()
                    Text(style.mode == .blend ? "centro" : "colore")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if style.mode == .blend {
                    ColorPicker("Estremi", selection: Binding(
                        get: { style.secondary.color },
                        set: { settings.setGlowStyle(GlowStyle(mode: style.mode, primary: style.primary, secondary: GlowRGB($0)), for: kind) }
                    ))
                    .labelsHidden()
                    Text("estremi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                Button("Ripristina") {
                    settings.setGlowStyle(.default(for: kind), for: kind)
                }
                .disabled(style == .default(for: kind))
                .help("Torna al colore e alla modalità di serie per questo avviso")

                Button("Prova") { onPreviewGlow(style.palette) }
            }
        }
        .padding(.vertical, 2)
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

                Toggle("Mostra freccia e icona progetti", isOn: $settings.notchShowsControls)
                if !settings.notchShowsControls {
                    Text("Senza di esse la barra è solo i due contatori: cliccane uno per aprire il pannello, e clicca fuori dal pannello per richiuderlo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

    /// The menu bar item is optional, so everything it offers has to be reachable
    /// from here — see the comment on `showMenuBarIcon`.
    private var menuBarSection: some View {
        Section("Barra dei menu") {
            Toggle("Mostra l'icona di Claude Live", isOn: $settings.showMenuBarIcon)
            Toggle("Mostra la percentuale accanto all'icona", isOn: $settings.showPercentageInMenuBar)
                .disabled(!settings.showMenuBarIcon)

            if !settings.showMenuBarIcon {
                Text("Senza icona queste impostazioni si riaprono dalla rotella nel pannello, oppure aprendo di nuovo Claude Live dal Finder. Tutto ciò che stava solo nel menu è qui: aggiornare, aggiornare i progetti, mostrare o nascondere il pannello, e uscire.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

            Toggle("Pannello visibile", isOn: Binding(
                // Visibility is the panel controller's to change — it also has to
                // place the window — so the toggle asks it rather than writing the
                // preference behind its back.
                get: { settings.panelVisible },
                set: { _ in onTogglePanelVisibility() }
            ))
            Toggle("Pannello compresso", isOn: $settings.panelCollapsed)
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

            LabeledContent("Accesso al portachiavi") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(keychainTint)
                        .frame(width: 8, height: 8)
                    Text(keychainLabel)
                        .foregroundStyle(.secondary)
                }
            }

            if monitor.keychainAuthorization == .notAuthorized {
                // The one fact that explains an unexpected dialog, and the only one
                // nobody can guess: the authorisation is per **path**.
                Text("L'autorizzazione del portachiavi vale per il **percorso** dell'app, e questa copia gira da «\(Bundle.main.bundlePath)». Alla prossima lettura macOS chiederà la password: scegli «Sempre» e non la richiederà più per questa copia. Se ne tieni una sola, in Applicazioni, la richiesta non torna più.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Button(projects.isRefreshing ? "Aggiornamento…" : "Aggiorna progetti") {
                    projects.refresh(reason: "impostazioni")
                }
                .disabled(projects.isRefreshing)
                Button("Copia header") {
                    copyHeaders()
                }
                .disabled(monitor.rawHeaders.isEmpty)
            }

            HStack {
                if settings.debugLoggingEnabled {
                    Button("Apri log") {
                        Paths.ensureDirectories()
                        NSWorkspace.shared.open(Paths.logFile)
                    }
                }

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

            HStack {
                Spacer()
                Button("Esci da Claude Live", action: onQuit)
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
        let counters = String(format: "contatori al %.0f%%", settings.notchScale * 100)
        return "\(where_.prefix(1).uppercased() + where_.dropFirst()), \(sizes), \(counters)."
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

    private var keychainLabel: String {
        switch monitor.keychainAuthorization {
        case .granted: return "concesso a questa copia"
        case .notAuthorized: return "non concesso a questa copia"
        case .notFound: return "credenziali assenti"
        case .failed(let status): return "errore \(status)"
        case nil: return "verifica…"
        }
    }

    private var keychainTint: Color {
        switch monitor.keychainAuthorization {
        case .granted: return PanelTheme.color(for: .normal)
        case .notAuthorized, .notFound: return PanelTheme.color(for: .warning)
        case .failed: return PanelTheme.color(for: .danger)
        case nil: return .secondary
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
