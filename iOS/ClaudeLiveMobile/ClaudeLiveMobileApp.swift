import SwiftUI
import UIKit

/// Remote notifications still arrive through the app delegate: SwiftUI has no
/// equivalent hook for the APNs token, so this is the one piece of UIKit the
/// app needs.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set by the app before registration is requested.
    static weak var probe: RelayProbe?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in AppDelegate.probe?.didRegister(tokenData: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in AppDelegate.probe?.didFailToRegister(error: error) }
    }
}

@main
struct ClaudeLiveMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var probe = RelayProbe()

    var body: some Scene {
        WindowGroup {
            ProbeView(probe: probe)
                .onAppear { AppDelegate.probe = probe }
        }
    }
}
