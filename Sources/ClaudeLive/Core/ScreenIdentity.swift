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
///
/// Carries enough to draw a faithful little picture of the screen: the point size
/// gives the aspect ratio, and the cutout gives the minimum the notch can be on
/// that display.
struct ScreenOption: Identifiable, Equatable {
    let id: String
    let name: String
    /// True when the display has a physical cutout; false means the notch is drawn.
    let hasPhysicalNotch: Bool
    /// Size in points — what the aspect ratio of the preview is built from.
    let pointSize: CGSize
    /// Left edge in the global coordinate space, so the previews can be laid out in
    /// the order the displays physically sit in — the same order System Settings
    /// shows, which is how the user recognises which monitor is which.
    let originX: CGFloat
    /// Size in pixels, for showing the resolution.
    let pixelSize: CGSize
    /// The physical cutout, when there is one: it is the floor for the notch size.
    let cutoutSize: CGSize?
    let isMain: Bool

    /// The size the notch will actually have here, given a requested one.
    func effectiveNotchSize(requested: CGSize) -> CGSize {
        guard let cutoutSize else { return requested }
        return CGSize(
            width: max(requested.width, cutoutSize.width),
            height: max(requested.height, cutoutSize.height)
        )
    }
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

    /// The connected displays, **left to right as they physically sit**, so the
    /// previews line up the way System Settings shows them. Static so the menu bar
    /// can ask for them without keeping an observable object alive.
    static func options() -> [ScreenOption] {
        let main = NSScreen.main
        return NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }.map { screen in
            ScreenOption(
                id: ScreenIdentity.identifier(for: screen),
                name: screen.localizedName,
                hasPhysicalNotch: NotchGeometry.hasPhysicalNotch(screen),
                pointSize: screen.frame.size,
                originX: screen.frame.minX,
                pixelSize: CGSize(
                    width: screen.frame.width * screen.backingScaleFactor,
                    height: screen.frame.height * screen.backingScaleFactor
                ),
                cutoutSize: NotchGeometry.cutoutSize(of: screen),
                isMain: screen == main
            )
        }
    }
}
