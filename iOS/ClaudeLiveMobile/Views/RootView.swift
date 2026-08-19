import SwiftUI
import ClaudeLiveKit

/// What the app shows today.
///
/// The Mac cannot publish anything yet, so the dashboard is filled with the
/// sample snapshot and says so in a banner. Showing the real, empty screen would
/// be more truthful but useless: the point of this stage is to judge the design,
/// and a design is judged against content.
///
/// The banner is not decoration. An app that shows convincing fake data without
/// admitting it is one screenshot away from being mistaken for a working one.
struct RootView: View {
    @ObservedObject var probe: RelayProbe
    @State private var showingSettings = false

    var body: some View {
        DashboardView(
            snapshot: RemoteSnapshot.sample(now: Date()),
            problem: "Dati d'esempio: il Mac non pubblica ancora nulla.",
            inFlight: [],
            onDecide: { _, _, _ in },
            onRefresh: {},
            onOpenSettings: { showingSettings = true }
        )
        .sheet(isPresented: $showingSettings) {
            ProbeView(probe: probe)
        }
    }
}

#Preview {
    RootView(probe: RelayProbe())
}
