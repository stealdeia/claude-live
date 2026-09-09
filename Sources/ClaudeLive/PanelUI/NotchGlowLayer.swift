import AppKit
import QuartzCore
import SwiftUI
import ClaudeLiveKit

/// The notification strip on screen, drawn by Core Animation.
///
/// ## Why not SwiftUI
///
/// The strip used to be a `TimelineView` that rebuilt itself on every frame, and
/// it cost about half a core for as long as an alert went unacknowledged — which
/// can be all night. Two things made it expensive, and the animation was neither
/// of them:
///
///   * `.blur` puts a layer past what the GPU can composite, so Core Animation
///     fell back to rasterising the whole strip on the CPU, once per frame;
///   * the hosting view ran a full SwiftUI layout pass on every display cycle
///     regardless of what the view produced — capping the frame rate barely
///     dented it, which is what made clear it had to come out of SwiftUI.
///
/// See `GlowBand.frameInterval` for the measurements.
///
/// ## What replaces it
///
/// Nothing about the strip's *geometry* changes while it breathes: the outline is
/// fixed, and only the light travelling along it moves. So the geometry is drawn
/// **once** into bitmap masks with the blur baked in, and the light is a
/// `CAGradientLayer` behind each of them, animated by a `CAKeyframeAnimation` on
/// `colors`. Core Animation runs that on the render server, so once it is
/// installed this process does no work per frame at all — masks are redrawn only
/// when the shape itself changes, which is when the panel opens or closes.
///
/// ## Why three layers and not one mask
///
/// The passes could be merged into a single mask, and the result would be wrong.
/// Compositing is not linear: where all three overlap, the core comes out at
/// roughly three times the brightness of one pass, and that is precisely what
/// makes it read as a bright line inside a halo rather than as a uniform smear.
/// Multiplying one gradient by one combined mask would flatten it. Keeping them
/// apart reproduces the old arithmetic exactly, and three composited layers is
/// nothing to a GPU.
@MainActor
final class NotchGlowLayerView: NSView {
    /// One pass of the strip: how wide, how soft, how much of it survives.
    private struct Pass {
        let lineWidth: CGFloat
        let blur: CGFloat
        let opacity: Double
    }

    /// Bloom first, core last — the same three `NotchGlowView` draws for stills.
    private static let passes = [
        Pass(lineWidth: 11, blur: 7, opacity: 0.75),
        Pass(lineWidth: 5.5, blur: 1.6, opacity: 1),
        Pass(lineWidth: 3, blur: 0, opacity: 1)
    ]

    /// How finely the phase curve is sampled for the keyframes.
    ///
    /// Not a frame rate: Core Animation interpolates between these, so it is how
    /// many straight segments stand in for the curve. Forty over `GlowBand.period`
    /// is far below what the eye can pick out in a movement this slow, and the
    /// whole set is built once, when the palette changes.
    private static let keyframes = 40

    private static let animationKey = "glow.travel"

    private static let locations: [NSNumber] = (0...GlowBand.samples).map {
        NSNumber(value: GlowBand.position(ofStop: $0))
    }

    private let horizontalMargin: CGFloat
    private let bottomMargin: CGFloat
    private let gradientLayers: [CAGradientLayer]

    private var palette: NotchGlowPalette?
    private var cornerRadius: CGFloat = NotchGeometry.collapsedCornerRadius
    /// What the masks were last drawn for, so they are redrawn only when they
    /// would come out different — during an open they would otherwise be redrawn
    /// on every frame of it.
    private var masksDrawnFor: MaskKey?

    private struct MaskKey: Equatable {
        let size: CGSize
        let cornerRadius: CGFloat
        let scale: CGFloat
    }

    init(horizontalMargin: CGFloat, bottomMargin: CGFloat) {
        self.horizontalMargin = horizontalMargin
        self.bottomMargin = bottomMargin
        self.gradientLayers = Self.passes.map { _ in CAGradientLayer() }
        super.init(frame: .zero)

        wantsLayer = true
        // The bloom spreads outside the outline; the margins are the room it has
        // to spread into, and clipping would cut it off at the window's edge.
        layer?.masksToBounds = false

        for gradient in gradientLayers {
            gradient.locations = Self.locations
            gradient.masksToBounds = false
            gradient.mask = CALayer()
            layer?.addSublayer(gradient)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Nil turns the strip off — animation included.
    ///
    /// Hiding it is not enough on its own: a hidden layer's animation still ticks
    /// on the render server, which is exactly the cost this class exists to avoid.
    func setGlow(_ palette: NotchGlowPalette?, bottomCornerRadius: CGFloat) {
        let paletteChanged = palette != self.palette
        self.palette = palette
        self.cornerRadius = bottomCornerRadius
        isHidden = palette == nil

        guard palette != nil else {
            for gradient in gradientLayers { gradient.removeAnimation(forKey: Self.animationKey) }
            return
        }

        updateGeometry()
        if paletteChanged || gradientLayers[0].animation(forKey: Self.animationKey) == nil {
            startTravelling()
        }
    }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry()
    }

    // MARK: Geometry

    private func updateGeometry() {
        guard palette != nil else { return }
        let size = bounds.size
        guard size.width > horizontalMargin * 2, size.height > bottomMargin else { return }
        let scale = window?.backingScaleFactor ?? 2

        CATransaction.begin()
        // The window is resized a step at a time while the panel opens; letting
        // Core Animation interpolate these on top of that would make the light
        // trail behind the shape it belongs to.
        CATransaction.setDisableActions(true)
        for gradient in gradientLayers {
            gradient.frame = bounds
            // The band spans the *shape*, not the window: the margins are room for
            // the bloom, and a gradient starting at the window's edge would put the
            // light's centre off the middle of the notch.
            gradient.startPoint = CGPoint(x: horizontalMargin / size.width, y: 0.5)
            gradient.endPoint = CGPoint(x: 1 - horizontalMargin / size.width, y: 0.5)
            gradient.mask?.frame = bounds
            gradient.mask?.contentsScale = scale
        }
        CATransaction.commit()

        let key = MaskKey(size: size, cornerRadius: cornerRadius, scale: scale)
        guard masksDrawnFor != key else { return }
        masksDrawnFor = key
        redrawMasks(size: size, scale: scale)
    }

    private func redrawMasks(size: CGSize, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (pass, gradient) in zip(Self.passes, gradientLayers) {
            gradient.mask?.contents = maskImage(pass: pass, size: size, scale: scale)
        }
        CATransaction.commit()
    }

    /// The pass as a bitmap: its stroke, blurred, in white. Only the alpha is ever
    /// read — it is a mask — so the colour is arbitrary.
    private func maskImage(pass: Pass, size: CGSize, scale: CGFloat) -> CGImage? {
        let content = NotchShape(
            topFlareRadius: NotchGeometry.flareRadius,
            bottomCornerRadius: cornerRadius
        )
        .stroke(Color.white, lineWidth: pass.lineWidth)
        .blur(radius: pass.blur)
        .opacity(pass.opacity)
        // The shape is the notch's, so it hangs from the top of the view inside
        // the margins — the same placement `NotchGlowView` gives it.
        .padding(.horizontal, horizontalMargin)
        .padding(.bottom, bottomMargin)
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        return renderer.cgImage
    }

    // MARK: The light

    private func startTravelling() {
        guard let palette else { return }

        // Colour depends only on where a stop sits, brightness only on the phase.
        // So the palette is sampled once — 49 conversions, not 49 per keyframe —
        // and every keyframe reuses it, varying nothing but alpha.
        let base: [(distance: Double, rgb: GlowRGB)] = (0...GlowBand.samples).map { index in
            let distance = GlowBand.distance(atPosition: GlowBand.position(ofStop: index))
            return (distance, GlowRGB(palette.color(atDistance: distance)))
        }

        let values: [[CGColor]] = (0...Self.keyframes).map { step in
            let moment = Double(step) / Double(Self.keyframes) * GlowBand.period
            let phase = GlowBand.phase(at: Date(timeIntervalSinceReferenceDate: moment))
            return base.map { stop in
                CGColor(
                    srgbRed: stop.rgb.red,
                    green: stop.rgb.green,
                    blue: stop.rgb.blue,
                    alpha: GlowBand.brightness(atDistance: stop.distance, phase: phase)
                )
            }
        }

        // Both clocks read the same cycle, but from different epochs: `phase(at:)`
        // counts from the reference date, Core Animation from boot. Rewinding the
        // start by how far into a cycle we are lines them up, so the notch and the
        // rows of the panel breathe together instead of being offset by whatever
        // separated their two starts.
        let intoCycle = Date().timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: GlowBand.period)

        for gradient in gradientLayers {
            gradient.colors = values[0]

            let travel = CAKeyframeAnimation(keyPath: "colors")
            travel.values = values
            travel.duration = GlowBand.period
            travel.repeatCount = .infinity
            travel.calculationMode = .linear
            travel.beginTime = CACurrentMediaTime() - intoCycle
            gradient.add(travel, forKey: Self.animationKey)
        }
    }
}
