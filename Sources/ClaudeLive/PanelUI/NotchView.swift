import SwiftUI
import ClaudeLiveKit

/// The notch surface.
///
/// Collapsed, it is a black bar hugging the physical notch: the chevron and the
/// 5h ring on the left, the 7d ring and the projects button on the right, with the
/// cutout itself as a gap in the middle. Expanded, the black shape grows **both
/// downward and outward** while the two rings stay exactly where they were —
/// they are pinned to the notch edges, and the extra width appears as black space
/// beyond them.
///
/// ## Why the layout looks inside-out
///
/// The content is **always** laid out at the expanded width and full height, and
/// the window clips it. Growing the window is the animation; nothing here resizes.
///
/// That is the fix for two earlier failures:
///   * letting SwiftUI animate its own size and having the window follow meant two
///     systems fighting over the geometry, and the content was re-laid out at a
///     different width on every frame — visibly steppy;
///   * using a big fixed transparent window and animating only the shape was
///     smooth, but the transparent area swallowed every click around the notch in
///     every app (a view's `hitTest` returning nil discards the event rather than
///     forwarding it to the window below).
///
/// Window size == painted size at all times, so clicks can never be stolen, and
/// the animation is a single Core Animation sequence on the window frame.
struct NotchView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var projects: ProjectsMonitor
    @ObservedObject var status: ClaudeStatusStore
    @ObservedObject var settings: Settings

    let geometry: NotchGeometry
    let actions: PanelActions

    @Binding var isExpanded: Bool

    /// Reports the detail's natural height so the controller knows how tall to
    /// animate the window. Measured at the final width, so it never changes
    /// mid-animation.
    let onDetailHeightChange: (CGFloat) -> Void

    /// The pointer entered or left the surface.
    ///
    /// Reported separately instead of just writing `isExpanded`, because the
    /// controller has to know that a panel is open *because* the pointer is on
    /// it: that is the only kind it may close behind SwiftUI's back.
    let onHoverChange: (Bool) -> Void

    private var barHeight: CGFloat { geometry.barHeight }
    private var scale: Double { settings.notchScale }
    private var showsControls: Bool { settings.notchShowsControls }
    private var stripWidth: CGFloat {
        geometry.stripWidth(scale: scale, showsControls: showsControls)
    }
    /// Width of the black *body* when collapsed — the window is wider than this
    /// by one flare on each side.
    private var collapsedBodyWidth: CGFloat {
        geometry.collapsedBodyWidth(scale: scale, showsControls: showsControls)
    }

    var body: some View {
        // `Color.clear` is the anchor: it accepts exactly the size the window
        // proposes, which is what pins everything else.
        //
        // A `ZStack` with `.frame(maxWidth:.infinity, maxHeight:.infinity)` was
        // wrong here and failed in a confusing way. Those are *maximums*, not
        // constraints: the stack grew to its oversized child (600×~330) and
        // SwiftUI then centred that in the 32pt-tall window, so the visible strip
        // showed the middle of the panel — a black bar with nothing in it.
        Color.clear
            .background(background)
            // `fixedSize` keeps the content at its natural size and the .top
            // alignment anchors it, so the collapsed window reveals its first
            // 32pt: exactly the strip row.
            .overlay(alignment: .top) { content.fixedSize() }
            // The rest of the content overflows the collapsed window on purpose.
            .clipped()
            .environment(\.colorScheme, .dark)
            // Only the corner radius and the content's opacity animate here; the
            // size is the controller's job. Kept a touch quicker than the frame so
            // the content is already legible while the panel is still settling.
            .animation(
                .easeOut(duration: isExpanded ? 0.22 : 0.16),
                value: isExpanded
            )
            .onHover { hovering in
                guard settings.notchExpandOnHover else { return }
                onHoverChange(hovering)
            }
    }

    /// Fills the window, so the flares and the rounded bottom corners always sit
    /// on the window's edge rather than on the content's.
    private var background: some View {
        NotchShape(
            topFlareRadius: NotchGeometry.flareRadius,
            bottomCornerRadius: isExpanded
                ? NotchGeometry.expandedCornerRadius
                : NotchGeometry.collapsedCornerRadius
        )
        // Pure black, not a material: anything translucent would stop the panel
        // reading as an extension of the notch.
        .fill(Color.black)
    }

    /// Fixed at the expanded width so no measurement or layout depends on the
    /// window's current, animating size.
    private var content: some View {
        VStack(spacing: 0) {
            topRow
            detail
                .opacity(isExpanded ? 1 : 0)
                // Invisible content must not intercept clicks on the strips.
                .allowsHitTesting(isExpanded)
        }
        .frame(width: NotchGeometry.expandedWidth)
    }

    // MARK: - Collapsed row (always visible, aligned with the notch)

    /// The inner frame keeps the strips hugging the cutout; the outer frame
    /// centres them in the full width. Without it, the strips would drift
    /// outwards as the window widens.
    private var topRow: some View {
        HStack(spacing: 0) {
            leftStrip
            // The cutout. Nothing is drawn here: on a real notch the black shape
            // behind merges with the hole, and on a screen without one the same
            // black *is* the drawn notch.
            Spacer().frame(width: geometry.notchRect.width)
            rightStrip
        }
        .frame(width: collapsedBodyWidth, height: barHeight)
        .frame(width: NotchGeometry.expandedWidth, height: barHeight)
    }

    /// Rings hug the cutout, controls sit in a fixed slot on the outer side and are
    /// centred in it, so the two sides mirror each other around the cutout.
    private var leftStrip: some View {
        HStack(spacing: 0) {
            if showsControls {
                NotchIconButton(
                    symbol: isExpanded ? "chevron.up" : "chevron.down",
                    help: isExpanded ? "Chiudi i dettagli" : "Apri i dettagli"
                ) {
                    toggle()
                }
                .frame(width: NotchGeometry.controlSlot)
            } else {
                Spacer().frame(width: NotchGeometry.ringOuterPad)
            }

            ringButton(window: monitor.snapshot?.fiveHour, label: "5h", title: "Sessione 5h")
        }
        .padding(.trailing, NotchGeometry.ringInset)
        .frame(width: stripWidth, height: barHeight)
    }

    private var rightStrip: some View {
        HStack(spacing: 0) {
            ringButton(window: monitor.snapshot?.sevenDay, label: "7g", title: "Settimana 7g")

            if showsControls {
                projectsButton
                    .frame(width: NotchGeometry.controlSlot)
            } else {
                Spacer().frame(width: NotchGeometry.ringOuterPad)
            }
        }
        .padding(.leading, NotchGeometry.ringInset)
        .frame(width: stripWidth, height: barHeight)
    }

    /// Projects button: opens the detail, and carries how many projects are open.
    ///
    /// It used to turn into a bell with a count when something needed the user. The
    /// luminous strip says that now — all around the notch instead of in 10pt of
    /// glyph — so this went back to being just a button.
    private var projectsButton: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 1.5) {
                Image(systemName: "folder")
                    .font(.system(size: 9.5, weight: .semibold))
                if !projects.projects.isEmpty {
                    Text("\(projects.projects.count)")
                        .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(Color.white.opacity(0.75))
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Progetti")
    }

    /// A ring that doubles as the "open the details" affordance — the only one
    /// when the controls are hidden. The exact percentage is deliberately only in
    /// the expanded panel, so the tooltip carries it for a quick look.
    private func ringButton(window: UsageWindow?, label: String, title: String) -> some View {
        Button {
            toggle()
        } label: {
            UsageRing(
                window: window,
                label: label,
                warn: settings.warnThreshold,
                danger: settings.dangerThreshold,
                diameter: geometry.ringDiameter(scale: scale)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip(title: title, window: window))
    }

    private func tooltip(title: String, window: UsageWindow?) -> String {
        guard let window else { return "\(title): nessun dato" }
        var text = "\(title): \(Format.percent(window.utilization))"
        if let resetAt = window.resetAt {
            text += "\nReset in \(Format.countdown(to: resetAt))"
        }
        return text
    }

    // MARK: - Expanded detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Color.white.opacity(0.12))

            PendingRequestsView(status: status, onFocusProject: actions.focusProject)

            // Fixed order — utilizzo, poi progetti — whichever control opened the
            // panel. It used to depend on that: the projects button put the list
            // first, the chevron put it second, so the same panel had two layouts
            // and you could not learn where anything was. It also matches the
            // floating panel, which shares these very views.
            UsageSectionView(monitor: monitor, settings: settings)

            Divider().overlay(Color.white.opacity(0.12))

            ProjectsSectionView(
                projects: projects,
                status: status,
                settings: settings,
                onInstallHooks: actions.installHooks
            )

            footer
        }
        // The flare inset applies to the whole body, not just the top row, so the
        // detail has to stay clear of it too.
        .padding(.horizontal, 18 + NotchGeometry.flareRadius)
        .padding(.bottom, 14)
        .padding(.top, 6)
        // Measured, not guessed: the controller needs the exact height to know
        // how far to grow the window.
        .overlay {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onDetailHeightChange(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, newValue in
                        onDetailHeightChange(newValue)
                    }
            }
            .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let fetchedAt = monitor.snapshot?.fetchedAt {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Text("Aggiornato \(Format.age(since: fetchedAt, now: context.date))")
                        .font(PanelTheme.captionFont)
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            if case .unavailable(let message) = monitor.state {
                Text(message)
                    .font(PanelTheme.captionFont)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            NotchIconButton(symbol: "arrow.clockwise", help: "Aggiorna", action: actions.refreshNow)
            NotchIconButton(symbol: "gearshape", help: "Impostazioni", action: actions.openSettings)
        }
    }

    // MARK: - Expansion

    private func toggle() {
        setExpanded(!isExpanded)
    }

    /// Only flips the flag. The window animation is the controller's job — one
    /// animation, one owner.
    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
    }
}

/// Icon button sized for the notch row, tuned for a black background.
struct NotchIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.14 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(0.75))
        .onHover { isHovering = $0 }
        .help(help)
    }
}
