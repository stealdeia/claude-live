import AppKit
import SwiftUI
import Combine
import QuartzCore

/// Owns the notch surface: window, geometry, and the expanded/collapsed state.
///
/// ## Who owns the animation
///
/// This controller does, and it is the only owner. Opening and closing drives the
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
final class NotchController: NSObject, ObservableObject {
    @Published private var isExpanded = false
    @Published private var emphasiseProjects = false

    private var window: NotchWindow?
    private var hosting: NSHostingController<NotchView>?
    private var geometry: NotchGeometry?

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

    /// True when this Mac actually has a notch to attach to.
    var isSupported: Bool { NotchGeometry.current() != nil }

    init(
        monitor: UsageMonitor,
        projects: ProjectsMonitor,
        status: ClaudeStatusStore,
        settings: Settings,
        actions: PanelActions
    ) {
        self.monitor = monitor
        self.projects = projects
        self.status = status
        self.settings = settings
        self.actions = actions
        super.init()

        // Lid opened/closed, display attached, resolution changed: the notch may
        // appear, move or vanish.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    // MARK: - Lifecycle

    func show() {
        guard let geometry = NotchGeometry.current() else {
            Log.error("Modalità notch richiesta ma nessuno schermo con notch trovato", category: .panel)
            return
        }
        self.geometry = geometry

        if window == nil {
            build(with: geometry)
        }
        applyFrame(expanded: isExpanded, animated: false)
        window?.orderFrontRegardless()
        Log.info(
            "Notch attivo su «\(geometry.screen.localizedName)»: cutout \(Int(geometry.notchRect.width))×\(Int(geometry.barHeight))pt a x=\(Int(geometry.notchRect.minX))",
            category: .panel
        )
    }

    func hide() {
        stopAnimation()
        window?.orderOut(nil)
        // Collapse so re-showing starts compact.
        isExpanded = false
        emphasiseProjects = false
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Renders the surface to a PNG next to the logs.
    ///
    /// Exists because verifying this UI otherwise needs a screenshot, and
    /// `screencapture` requires the Screen Recording permission. Drawing our own
    /// view needs no permission at all, which makes it the only way to check the
    /// notch's appearance from a script.
    func writeSnapshot(to url: URL) {
        guard let view = hosting?.view else { return }
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

    /// Expand/collapse from outside the view, for the menu and for diagnostics.
    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
    }

    private func build(with geometry: NotchGeometry) {
        let initial = CGSize(
            width: geometry.collapsedWidth(scale: settings.notchScale),
            height: geometry.barHeight
        )

        let hosting = NSHostingController(rootView: makeView(geometry: geometry))
        // The controller owns the size; SwiftUI must not propose one, or it would
        // race the frame animation.
        hosting.sizingOptions = []

        let window = NotchWindow(contentRect: geometry.frame(for: initial))
        window.contentViewController = hosting

        self.hosting = hosting
        self.window = window

        // Keep the hosted view's bindings in sync with our published state, and
        // animate the window whenever the expanded flag flips.
        $isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                Task { @MainActor in
                    self?.refreshRootView()
                    self?.animateFrame(expanded: expanded)
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

    private func makeView(geometry: NotchGeometry) -> NotchView {
        NotchView(
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

    private func refreshRootView() {
        guard let geometry else { return }
        hosting?.rootView = makeView(geometry: geometry)
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
        guard let geometry else { return .zero }
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

    private func animateFrame(expanded: Bool) {
        applyFrame(expanded: expanded, animated: true)
    }

    private func applyFrame(expanded: Bool, animated: Bool) {
        guard let window, let geometry else { return }
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
        guard let window, let view = hosting?.view else { return }
        stopAnimation()

        animationFromSize = window.frame.size
        animationToSize = targetSize
        animationIsOpening = opening
        animationDuration = opening ? NotchGeometry.openDuration : NotchGeometry.closeDuration
        animationStart = CACurrentMediaTime()

        let link = view.displayLink(target: self, selector: #selector(animationStep))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func animationStep() {
        guard let window, let geometry else {
            stopAnimation()
            return
        }

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

    @objc private func screenParametersChanged() {
        guard let updated = NotchGeometry.current() else {
            // Lid closed or external-only: nothing to attach to.
            Log.info("Notch non più disponibile, nascondo la superficie", category: .panel)
            hide()
            return
        }
        geometry = updated
        refreshRootView()
        applyFrame(expanded: isExpanded, animated: false)
        if settings.displayMode == .notch { window?.orderFrontRegardless() }
    }
}
