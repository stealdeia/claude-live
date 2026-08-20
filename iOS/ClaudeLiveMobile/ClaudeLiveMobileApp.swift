import SwiftUI
import UIKit

/// Remote notifications still arrive through the app delegate: SwiftUI has no
/// equivalent hook for the APNs token, so this is the one piece of UIKit the
/// app needs.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set by the app before registration is requested.
    static weak var probe: RelayProbe?
    static weak var store: RemoteStore?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Handed to both: the store is what the Mac's alerts reach, the probe is
        // the phase 0 stopwatch. Whichever asked for registration, the token is
        // the same and both need it.
        Task { @MainActor in
            AppDelegate.probe?.didRegister(tokenData: deviceToken)
            await AppDelegate.store?.registerDevice(token: deviceToken)
        }
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
            RootView(probe: probe)
                .onAppear { AppDelegate.probe = probe }
        }
    }
}
