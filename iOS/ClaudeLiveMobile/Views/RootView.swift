import SwiftUI
import ClaudeLiveKit

/// Three tabs: Home, Progetti, Utilizzo.
///
/// The split follows how often a thing is looked at, not how it is stored. Home
/// answers "does anything need me?" in one glance and links onwards; the other
/// two are where you go when the answer is yes, or when you want the detail.
///
/// Visible only once a Mac is paired. Before that there is nothing true to show,
/// and `WelcomeView` explains how to get there instead.
struct RootView: View {
    @ObservedObject var probe: RelayProbe
    @StateObject private var store = RemoteStore()
    @State private var themes = ThemeStore()
    @State private var tab: AppTab = .home
    @State private var showingSettings = false
    @State private var showingPairing = false
    @StateObject private var notifications = NotificationPreferences()
    @StateObject private var glow = GlowSettings()
    @StateObject private var glowState = GlowState()
    @StateObject private var currentAlert = CurrentAlert()
    @StateObject private var liveActivity = LiveActivityController()
    @StateObject private var openRequest = OpenRequest()
    @Environment(\.scenePhase) private var scenePhase

    enum AppTab: Hashable { case home, projects, usage }

    /// Whatever the Mac published, and nothing invented to fill a gap.
    ///
    /// It used to fall back to a sample snapshot when no Mac was paired, from
    /// when the Mac could not publish at all and a design had to be judged
    /// against something. Kept past that point it became an app showing invented
    /// numbers to whoever opened it for the first time — for a tool whose only
    /// job is to say what is actually happening, the worst thing it could do.
    private var snapshot: RemoteSnapshot? { store.snapshot }

    var body: some View {
        Group {
            if store.isPaired {
                tabs
            } else {
                WelcomeView(
                    onPair: { showingPairing = true },
                    onOpenSettings: { showingSettings = true }
                )
            }
        }
        .tint(themes.theme.accent)
        .environment(\.theme, themes.theme)
        .environmentObject(glowState)
        .environmentObject(glow)
        .environmentObject(currentAlert)
        .environmentObject(openRequest)
        // Il tocco sull'isola dinamica arriva qui, come indirizzo.
        .onOpenURL { url in open(url) }
        .onChange(of: snapshot?.alert) { _, alert in currentAlert.alert = alert }
        // L'isola segue la fotografia: ogni volta che il Mac dice qualcosa di
        // nuovo, il contenuto dell'attività si aggiorna.
        .onChange(of: snapshot?.generatedAt) { _, _ in
            Task { await liveActivity.sync(with: snapshot, alertSeen: alertAlreadySeen) }
        }
        // Anche quando spegni il bagliore entrando in una chat: l'isola deve
        // seguire lo stesso gesto, non aspettare la prossima fotografia.
        .onChange(of: glowState.dismissed) { _, _ in
            Task { await liveActivity.sync(with: snapshot, alertSeen: alertAlreadySeen) }
        }
        // Sopra tutto e senza intercettare i tocchi: è un segnale, non un
        // pulsante. Sfuma invece di sparire, perché entrare nella chat è già la
        // risposta e un taglio secco sembrerebbe un guasto.
        .overlay {
            if glow.enabled, let alert = snapshot?.alert, glowState.isLit(alert) {
                AppGlow(style: glow.style(for: alert.kind))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.55), value: glowState.dismissed)
        .animation(.easeOut(duration: 0.55), value: snapshot?.alert)
        // Forced dark: the whole look is a black-to-colour gradient, and there
        // is no light version of it that would still meet the Dynamic Island.
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(
                probe: probe,
                themes: themes,
                store: store,
                notifications: notifications,
                glow: glow,
                liveActivity: liveActivity
            ) {
                showingSettings = false
                showingPairing = true
            }
        }
        .sheet(isPresented: $showingPairing) {
            PairingView(store: store)
        }
        // Polls only while on screen: a phone asking from a pocket spends
        // battery to learn things nobody is reading.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.startRefreshing() } else { store.stopRefreshing() }
        }
        .onAppear {
            AppDelegate.store = store
            // Re-asserted on every launch: iOS can hand out a new token after a
            // reinstall or a restore, and the relay would go on pushing to the
            // old one — accepted by APNs, delivered to nobody.
            if store.isPaired {
                Task { await store.requestPushPermission() }
            }
            // Anche le scelte sulle notifiche vengono riaffermate, e per lo stesso
            // motivo: una spedita mentre il telefono era senza rete non ha
            // lasciato traccia, e il disallineamento non si vede — si vede solo
            // come una notifica che arriva quando l'interruttore dice di no.
            notifications.attach(to: store)
            liveActivity.attach(to: store)
            Task { await liveActivity.sync(with: snapshot, alertSeen: alertAlreadySeen) }
        }
        .onChange(of: store.isPaired) { _, paired in
            // Appena accoppiato il relay non sa ancora niente di questo telefono.
            if paired {
                notifications.attach(to: store)
                liveActivity.attach(to: store)
            }
        }
    }

    /// Apre quello che l'isola dinamica ha chiesto di aprire.
    ///
    /// `claudelive://chat/<sessione>` porta in quella chat, qualunque altra cosa
    /// porta in Home. Tollerante di proposito: un indirizzo che non si capisce
    /// deve aprire l'app, non far niente — chi ha toccato l'isola si aspetta di
    /// essere portato dentro.
    private func open(_ url: URL) {
        tab = .home
        guard url.scheme == "claudelive" else { return }
        if url.host == "chat" {
            let session = url.pathComponents.filter { $0 != "/" }.first
            if let session, !session.isEmpty { openRequest.chatSessionID = session }
            return
        }
        if url.host == "project" {
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "path" }?.value
            if let path, !path.isEmpty { openRequest.projectPath = path }
        }
    }

    /// Se l'avviso in corso è già stato preso in carico su questo telefono.
    private var alertAlreadySeen: Bool {
        guard let alert = snapshot?.alert else { return false }
        return !glowState.isLit(alert)
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                shell(title: "Vibing Code Live") {
                    HomeView(
                        snapshot: snapshot,
                        problem: store.problem,
                        inFlight: store.inFlight,
                        onDecide: { session, allow, remember in
                            Task { await store.decide(session, allow: allow, remember: remember) }
                        },
                        onAnswer: { session, answers in
                            Task { await store.answer(session, answers: answers) }
                        },
                        onOpenProjects: { tab = .projects },
                        onOpenUsage: { tab = .usage }
                    )
                }
            }

            Tab("Progetti", systemImage: "folder", value: AppTab.projects) {
                shell(title: "Progetti") {
                    ProjectsTabView(
                        snapshot: snapshot,
                        inFlight: store.inFlight,
                        onDecide: { session, allow, remember in
                            Task { await store.decide(session, allow: allow, remember: remember) }
                        },
                        onAnswer: { session, answers in
                            Task { await store.answer(session, answers: answers) }
                        }
                    )
                }
            }

            Tab("Utilizzo", systemImage: "chart.pie", value: AppTab.usage) {
                shell(title: "Utilizzo") {
                    UsageTabView(snapshot: snapshot)
                }
            }
        }
        .refreshable { await store.refresh() }
    }

    /// Navigation stack, gradient, title and the settings button — the frame
    /// every tab sits in.
    private func shell<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            ZStack {
                ThemedBackground()
                content()
            }
            .navigationTitle(title)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Impostazioni")
                }
            }
        }
    }
}

/// Settings: the theme, and the phase 0 stopwatch that is still useful for
/// checking the relay is reachable.
struct SettingsSheet: View {
    @ObservedObject var probe: RelayProbe
    @Bindable var themes: ThemeStore
    @ObservedObject var store: RemoteStore
    @ObservedObject var notifications: NotificationPreferences
    @ObservedObject var glow: GlowSettings
    @ObservedObject var liveActivity: LiveActivityController
    let onPair: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// Il tipo di avviso di cui si sta guardando l'anteprima del segnale.
    ///
    /// Esiste perché il segnale è l'unica cosa dell'app che non si può giudicare
    /// da un campione: va visto grande quanto lo schermo e in movimento. Prima
    /// serviva una domanda vera per vederlo — cioè far succedere qualcosa sul Mac
    /// per guardare un colore.
    @State private var previewing: ClaudeAlertKind?

    /// Spegne l'anteprima da sé: un segnale che resta accesso mentre si scelgono i
    /// colori diventa esso stesso il fastidio che si stava misurando.
    private static let previewSeconds: Double = 6

    var body: some View {
        NavigationStack {
            ZStack {
                ThemedBackground()
                    .environment(\.theme, themes.theme)
                ScrollView {
                    VStack(spacing: 16) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Mac")
                                    .font(.subheadline.weight(.semibold))

                                if store.isPaired {
                                    Label("Accoppiato", systemImage: "checkmark.circle.fill")
                                        .font(.footnote)
                                        .foregroundStyle(GlowRGB.done.color)
                                    Button("Disaccoppia", role: .destructive) { store.unpair() }
                                        .font(.footnote)
                                } else {
                                    Text("Nessun Mac accoppiato.")
                                        .font(.footnote)
                                        .foregroundStyle(.white.opacity(0.6))
                                    Button {
                                        onPair()
                                    } label: {
                                        Label("Accoppia con il Mac", systemImage: "qrcode.viewfinder")
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 4)
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Solo da accoppiati: senza un Mac non c'è nessuno che
                        // mandi notifiche, e tre interruttori inerti sembrano un
                        // guasto invece di una conseguenza.
                        if store.isPaired {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Notifiche")
                                        .font(.subheadline.weight(.semibold))

                                    Toggle("Quando Claude aspetta una risposta",
                                           isOn: $notifications.waiting)
                                    Toggle("Quando Claude ha finito",
                                           isOn: $notifications.done)
                                    Toggle("Quando Claude si interrompe",
                                           isOn: $notifications.failed)

                                    Text("Vale solo per questo telefono. Le notifiche sul Mac si scelgono nelle sue impostazioni.")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.55))

                                    if let problem = notifications.problem {
                                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption)
                                            .foregroundStyle(GlowRGB.waiting.color)
                                    }
                                }
                                .font(.footnote)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Segnale luminoso")
                                    .font(.subheadline.weight(.semibold))

                                Toggle("Illumina l'app quando arriva un avviso",
                                       isOn: $glow.enabled)
                                    .font(.footnote)

                                Text("Pulsa attorno allo schermo e sulla riga del progetto interessato, con lo stesso ritmo della striscia attorno al notch sul Mac. Si spegne entrando nella chat. Tocca un pallino colorato per vederlo in anteprima.")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.55))

                                ForEach(ClaudeAlertKind.allCases) { kind in
                                    glowRow(kind)
                                        .disabled(!glow.enabled)
                                        .opacity(glow.enabled ? 1 : 0.4)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Isola dinamica")
                                    .font(.subheadline.weight(.semibold))

                                Toggle("Mostra i contatori sull'isola",
                                       isOn: $liveActivity.enabled)
                                    .font(.footnote)

                                Text("Le due finestre di utilizzo restano visibili in cima allo schermo e sulla schermata di blocco. Toccando l'isola si apre con lo stato del progetto e la richiesta in sospeso.")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.55))

                                if let problem = liveActivity.keyProblem {
                                    Label(problem, systemImage: "key.slash.fill")
                                        .font(.caption)
                                        .foregroundStyle(GlowRGB.failed.color)
                                }

                                if let problem = liveActivity.problem {
                                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(GlowRGB.waiting.color)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Tema")
                                    .font(.subheadline.weight(.semibold))

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(ColorTheme.all) { theme in
                                            themeChip(theme)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Solo quando ha qualcosa da dire: da quando i campi
                        // dell'indirizzo sono spariti, senza misure restava un
                        // riquadro vuoto.
                        if !probe.measurements.isEmpty {
                            GlassCard {
                                ProbeSettings(probe: probe)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .overlay {
                if let kind = previewing {
                    ZStack {
                        // Uno strato invisibile che raccoglie il tocco: chi ha
                        // visto abbastanza non deve aspettare i sei secondi.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { previewing = nil }
                        AppGlow(style: glow.style(for: kind))
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.4), value: previewing)
            .preferredColorScheme(.dark)
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }

    /// Accende l'anteprima di un tipo di avviso e la spegne da sé.
    ///
    /// Lasciarla accesa mentre si scelgono i colori vorrebbe dire scegliere il
    /// colore dentro la cosa che si sta giudicando.
    private func preview(_ kind: ClaudeAlertKind) {
        previewing = kind
        Task {
            try? await Task.sleep(for: .seconds(Self.previewSeconds))
            if previewing == kind { previewing = nil }
        }
    }

    /// Un tipo di avviso: come si illumina e con quali colori.
    ///
    /// Le stesse tre modalità del Mac, con gli stessi nomi. Il pulsante
    /// «Ripristina» compare solo se c'è qualcosa da ripristinare, perché un
    /// pulsante che non fa niente insegna a non fidarsi dei pulsanti.
    private func glowRow(_ kind: ClaudeAlertKind) -> some View {
        let style = glow.style(for: kind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                // Il pallino *è* il pulsante di prova. Prima «Prova» era una
                // voce in più in una riga che in modalità «Sfumatura» conteneva
                // già due selettori di colore con le loro etichette: non ci
                // stava, e l'etichetta si spezzava in verticale una lettera per
                // riga. Mettere l'anteprima sul pallino accorcia la riga invece
                // di allungarla, e il pallino è già il colore di cui si vuole
                // vedere l'effetto.
                Button {
                    preview(kind)
                } label: {
                    ZStack {
                        Circle()
                            .fill(style.palette.color(atDistance: 0))
                            .frame(width: 22, height: 22)
                        Image(systemName: "play.fill")
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.black.opacity(0.55))
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)

                Text(kind.label)
                    .font(.footnote.weight(.medium))
                Spacer(minLength: 6)
                Picker("", selection: Binding(
                    get: { style.mode },
                    set: {
                        glow.setStyle(
                            GlowStyle(mode: $0, primary: style.primary, secondary: style.secondary),
                            for: kind
                        )
                    }
                )) {
                    ForEach(GlowStyle.Mode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.footnote)
            }

            HStack(spacing: 12) {
                if style.mode != .rainbow {
                    ColorPicker("", selection: Binding(
                        get: { style.primary.color },
                        set: {
                            glow.setStyle(
                                GlowStyle(mode: style.mode, primary: GlowRGB($0), secondary: style.secondary),
                                for: kind
                            )
                        }
                    ))
                    .labelsHidden()
                    Text(style.mode == .blend ? "centro" : "colore")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }

                if style.mode == .blend {
                    ColorPicker("", selection: Binding(
                        get: { style.secondary.color },
                        set: {
                            glow.setStyle(
                                GlowStyle(mode: style.mode, primary: style.primary, secondary: GlowRGB($0)),
                                for: kind
                            )
                        }
                    ))
                    .labelsHidden()
                    Text("estremi")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer(minLength: 4)

                // Un'icona e non una parola: in modalità «Sfumatura» questa riga
                // porta già due selettori, e un'etichetta che si accorcia da sé
                // è un'etichetta che diventa illeggibile.
                if !glow.isDefault(kind) {
                    Button {
                        glow.setStyle(.default(for: kind), for: kind)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityLabel("Ripristina i colori predefiniti")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func themeChip(_ theme: ColorTheme) -> some View {
        Button {
            themes.theme = theme
        } label: {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.top, theme.bloom, theme.deep],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 58, height: 84)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                themes.theme.id == theme.id ? theme.accent : .white.opacity(0.15),
                                lineWidth: themes.theme.id == theme.id ? 2 : 0.5
                            )
                    }
                Text(theme.name)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    RootView(probe: RelayProbe())
}
