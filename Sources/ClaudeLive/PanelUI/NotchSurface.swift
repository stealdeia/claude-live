import AppKit
import SwiftUI
import Combine
import QuartzCore

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
    @Published private var emphasiseProjects = false

    private let window: NotchWindow
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
            width: geometry.collapsedWidth(scale: settings.notchScale),
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

        window = NotchWindow(contentRect: geometry.frame(for: initial))
        window.contentViewController = hosting

        super.init()

        // Now that `self` exists, swap in the view whose bindings point back here.
        refreshRootView()

        $isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                Task { @MainActor in
                    self?.refreshRootView()
                    self?.applyFrame(expanded: expanded, animated: true)
                }
            }
            .store(in: &cancellables)

        $emphasiseProjects
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshRootView() }
            }
            .store(in: &cancellables)

        // A bigger ring widens the collapsed bar, so the window has to follow.
        settings.$notchScale
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshRootView()
                    self.applyFrame(expanded: self.isExpanded, animated: false)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func show() {
        // Logged once per appearance, not once per sync: macOS fires
        // `didChangeScreenParameters` a few times while displays settle at launch,
        // and each one re-syncs the surface set.
        let isFirstAppearance = !window.isVisible
        applyFrame(expanded: isExpanded, animated: false)
        window.orderFrontRegardless()
        guard isFirstAppearance else { return }
        Log.info(
            "Notch su «\(geometry.screenName)»: \(geometry.isVirtual ? "disegnato" : "cutout") \(Int(geometry.notchRect.width))×\(Int(geometry.barHeight))pt a x=\(Int(geometry.notchRect.minX))",
            category: .panel
        )
    }

    func close() {
        stopAnimation()
        window.orderOut(nil)
        window.contentViewController = nil
        cancellables.removeAll()
    }

    /// The screen moved or changed resolution but is still ours: re-place the
    /// window without animating a change the user did not ask for.
    func update(geometry: NotchGeometry) {
        guard geometry != self.geometry else { return }
        self.geometry = geometry
        refreshRootView()
        applyFrame(expanded: isExpanded, animated: false)
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
            emphasiseProjects: .constant(false),
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
            emphasiseProjects: Binding(
                get: { [weak self] in self?.emphasiseProjects ?? false },
                set: { [weak self] in self?.emphasiseProjects = $0 }
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
            width: geometry.collapsedWidth(scale: settings.notchScale),
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
        window.setFrame(geometry.frame(for: size), display: false)

        if linear >= 1 {
            window.setFrame(geometry.frame(for: animationToSize), display: false)
            stopAnimation()
        }
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
