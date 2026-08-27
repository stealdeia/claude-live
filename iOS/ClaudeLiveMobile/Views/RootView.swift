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
        .onChange(of: snapshot?.alert) { _, alert in currentAlert.alert = alert }
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
                glow: glow
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
        }
        .onChange(of: store.isPaired) { _, paired in
            // Appena accoppiato il relay non sa ancora niente di questo telefono.
            if paired { notifications.attach(to: store) }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                shell(title: "Claude Live") {
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
    let onPair: () -> Void
    @Environment(\.dismiss) private var dismiss

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

                                Text("Pulsa attorno allo schermo e sulla riga del progetto interessato, con lo stesso ritmo della striscia attorno al notch sul Mac. Si spegne entrando nella chat.")
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

    /// Un tipo di avviso: come si illumina e con quali colori.
    ///
    /// Le stesse tre modalità del Mac, con gli stessi nomi. Il pulsante
    /// «Ripristina» compare solo se c'è qualcosa da ripristinare, perché un
    /// pulsante che non fa niente insegna a non fidarsi dei pulsanti.
    private func glowRow(_ kind: ClaudeAlertKind) -> some View {
        let style = glow.style(for: kind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(style.palette.color(atDistance: 0))
                    .frame(width: 10, height: 10)
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

                if !glow.isDefault(kind) {
                    Button("Ripristina") {
                        glow.setStyle(.default(for: kind), for: kind)
                    }
                    .font(.caption)
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
