import AppKit
import Combine
import CoreGraphics

/// Stable identity for a display, so a chosen monitor is still the same monitor
/// after a reboot, a cable swap or a docking cycle.
///
/// `CGDirectDisplayID` is *not* usable for this: it is assigned per session and
/// changes when displays are reconnected in a different order.
/// `CGDisplayCreateUUIDFromDisplayID` returns an identifier tied to the panel
/// itself, which survives all of that.
///
/// `localizedName` is not usable either, though it looks tempting: two identical
/// monitors come back as "PHL 241E1 (1)" and "PHL 241E1 (2)", and which one gets
/// which suffix is not stable. It is still the right thing to *show*.
enum ScreenIdentity {
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let number = screen.deviceDescription[key] as? NSNumber
        return CGDirectDisplayID(number?.uint32Value ?? 0)
    }

    /// Persistable identifier. Falls back to the name only if the display has no
    /// UUID (virtual or software displays sometimes don't), which is better than
    /// having no way to select it at all.
    static func identifier(for screen: NSScreen) -> String {
        let id = displayID(for: screen)
        if let reference = CGDisplayCreateUUIDFromDisplayID(id) {
            let uuid = reference.takeRetainedValue()
            if let string = CFUUIDCreateString(nil, uuid) as String? {
                return string
            }
        }
        return "name:\(screen.localizedName)"
    }
}

/// One connected display, as offered in Settings.
struct ScreenOption: Identifiable, Equatable {
    let id: String
    let name: String
    /// True when the display has a physical cutout; false means the notch is drawn.
    let hasPhysicalNotch: Bool
    let pixelSize: CGSize
    let isMain: Bool
}

/// Publishes the list of connected displays, refreshed whenever the
/// configuration changes.
///
/// Exists because the settings window is often open exactly when the user is
/// plugging a monitor in, and a stale list there is worse than no list: it offers
/// a display that no longer exists.
@MainActor
final class ScreenCatalog: ObservableObject {
    @Published private(set) var screens: [ScreenOption] = []

    private var observer: Any?

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func reload() {
        screens = ScreenCatalog.options()
    }

    /// The connected displays, in AppKit's order. Static so the menu bar can ask
    /// for them without keeping an observable object alive.
    static func options() -> [ScreenOption] {
        let main = NSScreen.main
        return NSScreen.screens.map { screen in
            ScreenOption(
                id: ScreenIdentity.identifier(for: screen),
                name: screen.localizedName,
                hasPhysicalNotch: NotchGeometry.hasPhysicalNotch(screen),
                pixelSize: CGSize(
                    width: screen.frame.width * screen.backingScaleFactor,
                    height: screen.frame.height * screen.backingScaleFactor
                ),
                isMain: screen == main
            )
        }
    }
}
