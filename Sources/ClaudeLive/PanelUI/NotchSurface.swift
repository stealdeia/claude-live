import AppKit
import SwiftUI
import Combine
import QuartzCore
import ClaudeLiveKit

/// One notch surface on one screen: its window, its geometry and its animation.
///
/// Split out of `NotchController` when the notch became placeable on several
/// displays at once. Each surface expands independently — you open the one you
/// are looking at, and the others stay collapsed, which is the only behaviour
/// that makes sense when two monitors are side by side.
///
/// ## Who owns the animation
///
/// This class does, and it is the only owner. Opening and closing drives the
/// **window frame** directly from a display link, one step per screen refresh;
/// the SwiftUI content is laid out once at the final width and simply gets
/// clipped by the window.
///
/// Driving it by hand rather than through `NSAnimationContext` buys two things:
/// frames land in step with the display instead of on a timer, and the easing can
/// **overshoot** — `CAMediaTimingFunction` interpolates monotonically, so a
/// bounce is not expressible through it.
///
/// Two earlier attempts are worth remembering, because both failed in ways that
/// are easy to reintroduce:
///   * letting SwiftUI animate its own size with `sizingOptions =
///     [.preferredContentSize]` and having the window follow — two systems
///     fighting over the geometry, and a full content re-layout at a new width on
///     every frame. Visibly steppy;
///   * a large fixed transparent window with only the shape animating — smooth,
///     but it swallowed every click around the notch in every app.
///
/// Window size always equals painted size, so clicks can never be stolen.
@MainActor
final class NotchSurface: NSObject, ObservableObject {
    private(set) var geometry: NotchGeometry

    @Published private var isExpanded = false

    private let window: NotchWindow
    /// Behind `window`, and the only thing that draws the shadow — see `NotchShadow`.
    private let shadowWindow: NotchAuraWindow
    private let hosting: NSHostingController<NotchView>

    /// Natural height of the detail content, measured by the view at the final
    /// width. Nil until the first measurement lands.
    private var detailHeight: CGFloat?

    // Hand-rolled frame animation state.
    private var displayLink: CADisplayLink?
    private var animationFromSize: CGSize = .zero
    private var animationToSize: CGSize = .zero
    private var animationStart: CFTimeInterval = 0
    private var animationDuration: CFTimeInterval = 0
    private var animationIsOpening = false

    private let monitor: UsageMonitor
    private let projects: ProjectsMonitor
    private let status: ClaudeStatusStore
    private let settings: Settings
    private let actions: PanelActions

    private var cancellables: Set<AnyCancellable> = []
    private var spaceObserver: Any?
    /// Live only while the detail is open — see `updateClickOutsideMonitors`.
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    var screenID: String { geometry.screenID }
    var isVisible: Bool { window.isVisible }
    var windowFrame: CGRect { window.frame }
    var view: NSView { hosting.view }

    init(
        geometry: NotchGeometry,
        monitor: UsageMonitor,
        projects: ProjectsMonitor,
        status: ClaudeStatusStore,
        settings: Settings,
        actions: PanelActions
    ) {
        self.geometry = geometry
        self.monitor = monitor
        self.projects = projects
        self.status = status
        self.settings = settings
        self.actions = actions

        let initial = CGSize(
            width: geometry.collapsedWidth(
                scale: settings.notchScale,
                showsControls: settings.notchShowsControls
            ),
            height: geometry.barHeight
        )

        hosting = NSHostingController(rootView: NotchSurface.placeholderView(
            geometry: geometry,
            monitor: monitor,
            projects: projects,
            status: status,
            settings: settings,
            actions: actions
        ))
        // The surface owns the size; SwiftUI must not propose one, or it would
        // race the frame animation.
        hosting.sizingOptions = []

        let initialFrame = geometry.frame(for: initial)
        window = NotchWindow(contentRect: initialFrame)
        window.contentViewController = hosting
        shadowWindow = NotchAuraWindow(
            contentRect: NotchAuraWindow.frame(forNotchFrame: initialFrame)
        )

        super.init()

        // Now that `self` exists, swap in the view whose bindings point back here.
        refreshRootView()

        $isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                Task { @MainActor in
                    self?.refreshRootView()
                    self?.applyFrame(expanded: expanded, animated: true)
                    self?.updateClickOutsideMonitors(expanded: expanded)
                    // Fades over the same time the panel takes to open or close,
                    // so it arrives *with* the panel rather than after it.
                    self?.shadowWindow.setShadow(
                        visible: expanded,
                        duration: expanded
                            ? NotchGeometry.openDuration
                            : NotchGeometry.closeDuration
                    )
                    self?.logShadowState(expanded: expanded)
                }
            }
            .store(in: &cancellables)

        // A bigger ring widens the collapsed bar, and hiding the controls narrows
        // it, so the window has to follow either one.
        settings.$notchScale
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.relayout() }
            }
            .store(in: &cancellables)

        settings.$notchShowsControls
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.relayout() }
            }
            .store(in: &cancellables)

        // A Space created after launch never receives a `canJoinAllSpaces` window
        // on its own; switching to it is when we can hand it over.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reassertSpacePresence() }
        }
    }

    deinit {
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    }

    // MARK: - Lifecycle

    func show() {
        // Logged once per appearance, not once per sync: macOS fires
        // `didChangeScreenParameters` a few times while displays settle at launch,
        // and each one re-syncs the surface set.
        let isFirstAppearance = !window.isVisible
        applyFrame(expanded: isExpanded, animated: false)
        window.orderFrontRegardless()
        orderShadowBehindWindow()
        guard isFirstAppearance else { return }
        Log.info(
            "Notch su «\(geometry.screenName)»: \(geometry.isVirtual ? "disegnato" : "cutout") \(Int(geometry.notchRect.width))×\(Int(geometry.barHeight))pt a x=\(Int(geometry.notchRect.minX))",
            category: .panel
        )
    }

    func close() {
        stopAnimation()
        updateClickOutsideMonitors(expanded: false)
        shadowWindow.orderOut(nil)
        window.orderOut(nil)
        window.contentViewController = nil
        cancellables.removeAll()
    }

    /// Re-renders at the current settings and re-places the window, without
    /// animating a change the user did not ask for.
    private func relayout() {
        refreshRootView()
        applyFrame(expanded: isExpanded, animated: false)
    }

    /// Puts the surface back on the Space that just became active, and re-places it.
    ///
    /// See `NotchWindow.reassertSpacePresence` for why this is needed at all. The
    /// frame is re-applied too because a Space change can come with a display
    /// reconfiguration (a full-screen app on another monitor).
    private func reassertSpacePresence() {
        guard window.isVisible else { return }
        window.reassertSpacePresence()
        orderShadowBehindWindow()
        applyFrame(expanded: isExpanded, animated: false)
    }

    // MARK: - Click outside

    /// Closes the detail when a click lands anywhere but on it.
    ///
    /// The strips can be reduced to the two rings alone, and then the only other
    /// way to close would be clicking the very ring that opened it — so a click
    /// outside has to work. Two monitors are needed and neither is redundant: the
    /// global one sees clicks in *other* applications and never ours, the local one
    /// sees ours (Settings, the onboarding window) and never anyone else's.
    ///
    /// Mouse events need no special permission, unlike keyboard ones.
    private func updateClickOutsideMonitors(expanded: Bool) {
        guard expanded else {
            if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
            if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
            globalClickMonitor = nil
            localClickMonitor = nil
            return
        }
        guard globalClickMonitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.collapseIfClickIsOutside(NSEvent.mouseLocation) }
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            // A click on the surface itself is not "outside", and the buttons in
            // it must keep working — so the event is always passed through.
            if let self, event.window !== self.window {
                Task { @MainActor in self.collapseIfClickIsOutside(NSEvent.mouseLocation) }
            }
            return event
        }
    }

    private func collapseIfClickIsOutside(_ point: CGPoint) {
        guard isExpanded, !window.frame.contains(point) else { return }
        setExpanded(false)
    }

    /// The screen moved or changed resolution but is still ours: re-place the
    /// window without animating a change the user did not ask for.
    func update(geometry: NotchGeometry) {
        guard geometry != self.geometry else { return }
        self.geometry = geometry
        refreshRootView()
        applyFrame(expanded: isExpanded, animated: false)
    }

    /// Turns the notification strip on, in a given palette, or off with nil.
    func setGlow(_ palette: NotchGlowPalette?) {
        shadowWindow.setGlow(palette)
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
    }

    /// Renders the surface to a PNG next to the logs.
    ///
    /// Exists because verifying this UI otherwise needs a screenshot, and
    /// `screencapture` requires the Screen Recording permission. Drawing our own
    /// view needs no permission at all, which makes it the only way to check the
    /// notch's appearance from a script.
    func writeSnapshot(to url: URL) {
        let view = hosting.view
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Log.error("Snapshot notch: impossibile creare il bitmap", category: .panel)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: url)
            Log.info("Snapshot notch salvato: \(url.path) (\(Int(view.bounds.width))×\(Int(view.bounds.height)))", category: .panel)
        } catch {
            Log.error("Snapshot notch non salvato: \(error.localizedDescription)", category: .panel)
        }
    }

    // MARK: - View

    /// Bindings that do nothing, for the one instant between `NSHostingController`
    /// needing a root view and `self` being available to bind to.
    private static func placeholderView(
        geometry: NotchGeometry,
        monitor: UsageMonitor,
        projects: ProjectsMonitor,
        status: ClaudeStatusStore,
        settings: Settings,
        actions: PanelActions
    ) -> NotchView {
        NotchView(
            monitor: monitor,
            projects: projects,
            status: status,
            settings: settings,
            geometry: geometry,
            actions: actions,
            isExpanded: .constant(false),
            onDetailHeightChange: { _ in }
        )
    }

    private func refreshRootView() {
        hosting.rootView = NotchView(
            monitor: monitor,
            projects: projects,
            status: status,
            settings: settings,
            geometry: geometry,
            actions: actions,
            isExpanded: Binding(
                get: { [weak self] in self?.isExpanded ?? false },
                set: { [weak self] in self?.isExpanded = $0 }
            ),
            onDetailHeightChange: { [weak self] height in
                Task { @MainActor in self?.updateDetailHeight(height) }
            }
        )
    }

    // MARK: - Layout

    /// The detail's height changes when a project appears or disappears; keep the
    /// window in step, without animating a change the user did not ask for.
    private func updateDetailHeight(_ height: CGFloat) {
        guard height > 0, detailHeight != height else { return }
        detailHeight = height
        if isExpanded {
            applyFrame(expanded: true, animated: false)
        }
    }

    private func size(expanded: Bool) -> CGSize {
        if expanded {
            return CGSize(
                width: NotchGeometry.expandedWidth,
                // Fall back to a plausible height only until the first
                // measurement arrives; in practice it lands before the first open.
                height: geometry.barHeight + (detailHeight ?? 300)
            )
        }
        return CGSize(
            width: geometry.collapsedWidth(
                scale: settings.notchScale,
                showsControls: settings.notchShowsControls
            ),
            height: geometry.barHeight
        )
    }

    private func applyFrame(expanded: Bool, animated: Bool) {
        let targetSize = size(expanded: expanded)
        let target = geometry.frame(for: targetSize)

        guard animated else {
            stopAnimation()
            guard window.frame != target else { return }
            window.setFrame(target, display: true)
            syncShadow(notchFrame: target)
            return
        }

        guard window.frame.size != targetSize else { return }
        startAnimation(to: targetSize, opening: expanded)
    }

    // MARK: - Frame animation

    /// Animates from the window's *current* size, so re-triggering mid-flight
    /// retargets smoothly instead of snapping.
    private func startAnimation(to targetSize: CGSize, opening: Bool) {
        stopAnimation()

        animationFromSize = window.frame.size
        animationToSize = targetSize
        animationIsOpening = opening
        animationDuration = opening ? NotchGeometry.openDuration : NotchGeometry.closeDuration
        animationStart = CACurrentMediaTime()

        let link = hosting.view.displayLink(target: self, selector: #selector(animationStep))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func animationStep() {
        let elapsed = CACurrentMediaTime() - animationStart
        let linear = animationDuration > 0 ? min(1, elapsed / animationDuration) : 1
        let eased = animationIsOpening
            ? Self.easeOutBack(linear, overshoot: NotchGeometry.openOvershoot)
            : Self.easeOutCubic(linear)

        // Interpolate the *size* and re-derive the frame, so the surface stays
        // centred on the cutout and flush with the screen top even while the
        // overshoot pushes it past its target.
        let size = CGSize(
            width: animationFromSize.width + (animationToSize.width - animationFromSize.width) * eased,
            height: animationFromSize.height + (animationToSize.height - animationFromSize.height) * eased
        )
        setFrames(for: size)

        if linear >= 1 {
            setFrames(for: animationToSize)
            stopAnimation()
        }
    }

    /// Notch window first, then the shadow: both in the same turn of the run loop,
    /// which is what keeps the shadow welded to the shape instead of trailing it.
    private func setFrames(for size: CGSize) {
        let frame = geometry.frame(for: size)
        window.setFrame(frame, display: false)
        syncShadow(notchFrame: frame)
    }

    private func syncShadow(notchFrame: CGRect) {
        shadowWindow.setFrame(NotchAuraWindow.frame(forNotchFrame: notchFrame), display: false)
        shadowWindow.reshape(
            notchSize: notchFrame.size,
            // Matches the corner the view is drawing right now: the radius grows
            // with the panel, and a shadow with the collapsed corner would show a
            // dark notch at each bottom corner of an expanded panel.
            bottomCornerRadius: isExpanded
                ? NotchGeometry.expandedCornerRadius
                : NotchGeometry.collapsedCornerRadius
        )
    }

    /// The shadow is invisible by construction — a transparent window drawing only
    /// a blur — so "is it there" cannot be answered by looking at the code, and
    /// this machine has no Screen Recording permission to check by screenshot.
    /// These three facts are what a shadow needs to be seen: a window that is on
    /// screen, big enough to hold the blur, and behind the panel rather than over
    /// it.
    private func logShadowState(expanded: Bool) {
        func rect(_ r: CGRect) -> String {
            "\(Int(r.width))×\(Int(r.height))@\(Int(r.minX)),\(Int(r.minY))"
        }
        Log.debug(
            "Ombra \(expanded ? "in comparsa" : "in uscita"): notch=\(rect(window.frame)) "
            + "ombra=\(rect(shadowWindow.frame)) visibile=\(shadowWindow.isVisible) "
            + "dietro=\(Self.isBehind(shadowWindow, window) ?? false)",
            category: .panel
        )
    }

    /// Whether `back` really is behind `front`, asked of the window server.
    ///
    /// `NSWindow.orderedIndex` cannot answer it: both of these are non-activating
    /// panels above the menu bar, and AppKit reports `NSNotFound` for them and
    /// leaves them out of `NSApp.orderedWindows` entirely. The window server's own
    /// on-screen list is front-to-back, so comparing positions in it is the
    /// z-order.
    private static func isBehind(_ back: NSWindow, _ front: NSWindow) -> Bool? {
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let numbers = info.compactMap { $0[kCGWindowNumber as String] as? Int }
        guard let backIndex = numbers.firstIndex(of: back.windowNumber),
              let frontIndex = numbers.firstIndex(of: front.windowNumber)
        else { return nil }
        return backIndex > frontIndex
    }

    /// The shadow must stay directly below the surface it belongs to: same level,
    /// explicit order, re-asserted every time the notch window is ordered front.
    private func orderShadowBehindWindow() {
        shadowWindow.order(.below, relativeTo: window.windowNumber)
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Ease-out with a single small overshoot — the "bubble settling" feel.
    /// `overshoot` scales the classic constant; see `NotchGeometry.openOvershoot`.
    private static func easeOutBack(_ t: Double, overshoot: Double) -> Double {
        let c1 = 1.70158 * overshoot
        let c3 = c1 + 1
        let p = t - 1
        return 1 + c3 * p * p * p + c1 * p * p
    }

    /// Plain settle, no overshoot: used for closing.
    private static func easeOutCubic(_ t: Double) -> Double {
        let p = t - 1
        return 1 + p * p * p
    }
}
