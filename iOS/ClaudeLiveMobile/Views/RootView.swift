import SwiftUI
import ClaudeLiveKit

/// Three tabs: Home, Progetti, Utilizzo.
///
/// The split follows how often a thing is looked at, not how it is stored. Home
/// answers "does anything need me?" in one glance and links onwards; the other
/// two are where you go when the answer is yes, or when you want the detail.
///
/// The Mac cannot publish yet, so everything runs on the sample snapshot and the
/// app says so on Home. Showing the real, empty screen would be truthful and
/// useless: a design is judged against content.
struct RootView: View {
    @ObservedObject var probe: RelayProbe
    @StateObject private var store = RemoteStore()
    @State private var themes = ThemeStore()
    @State private var tab: AppTab = .home
    @State private var showingSettings = false
    @State private var showingPairing = false
    @Environment(\.scenePhase) private var scenePhase

    enum AppTab: Hashable { case home, projects, usage }

    /// The sample only until a Mac is paired. After that, whatever it published
    /// — and nothing invented to fill a gap: an empty screen that is true beats
    /// a full one that is not.
    private var snapshot: RemoteSnapshot? {
        store.isPaired ? store.snapshot : RemoteSnapshot.sample(now: Date())
    }

    private var problem: String? {
        if !store.isPaired { return "Dati d'esempio: nessun Mac accoppiato." }
        return store.problem
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                shell(title: "Claude Live") {
                    HomeView(
                        snapshot: snapshot,
                        problem: problem,
                        inFlight: [],
                        onDecide: { _, _, _ in },
                        onOpenProjects: { tab = .projects },
                        onOpenUsage: { tab = .usage }
                    )
                }
            }

            Tab("Progetti", systemImage: "folder", value: AppTab.projects) {
                shell(title: "Progetti") {
                    ProjectsTabView(snapshot: snapshot, inFlight: [], onDecide: { _, _, _ in })
                }
            }

            Tab("Utilizzo", systemImage: "chart.pie", value: AppTab.usage) {
                shell(title: "Utilizzo") {
                    UsageTabView(snapshot: snapshot)
                }
            }
        }
        .tint(themes.theme.accent)
        .environment(\.theme, themes.theme)
        // Forced dark: the whole look is a black-to-colour gradient, and there
        // is no light version of it that would still meet the Dynamic Island.
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(probe: probe, themes: themes, store: store) {
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
                                    Text("Nessun Mac accoppiato: l'app mostra dati d'esempio.")
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

                        GlassCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Tema")
                                    .font(.subheadline.weight(.semibold))

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(AppTheme.all) { theme in
                                            themeChip(theme)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        GlassCard {
                            ProbeSettings(probe: probe)
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

    private func themeChip(_ theme: AppTheme) -> some View {
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
