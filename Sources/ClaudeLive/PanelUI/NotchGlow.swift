import SwiftUI
import AppKit
import ClaudeLiveKit

/// The notification signal: a thin neon strip along the notch's outline, pulsing
/// from the centre out to both ends and back.
///
/// ## How it is drawn
///
/// The strip is the notch's own outline, stroked. It lives in the aura window,
/// *behind* the notch, and the stroke is deliberately about twice as wide as the
/// visible result: the panel's own black covers the inner half, so the occlusion
/// does the masking and what remains is a strip hugging the edge from outside.
/// Nothing has to be clipped by hand, and the light can never spill over the
/// content of the panel.
///
/// ## How it moves
///
/// Brightness is a function of horizontal position — a Gaussian band centred at
/// `distance == phase` — so one gradient with sampled stops draws both travelling
/// bands at once, and no animation has to be kept in sync with anything. A dim
/// floor keeps the whole outline faintly lit, so it reads as a strip that has
/// light running through it rather than as two dots chasing each other.
struct NotchGlowView: View {
    var palette: NotchGlowPalette
    /// Corner radius of the shape being traced; the notch's changes when it opens.
    var bottomCornerRadius: CGFloat
    /// Horizontal room the aura window leaves around the notch.
    var horizontalMargin: CGFloat
    /// Room below it.
    var bottomMargin: CGFloat
    /// Fixed phase, for rendering a filmstrip. Nil means "animate".
    var fixedPhase: Double?

    var body: some View {
        if let fixedPhase {
            strip(phase: fixedPhase)
        } else {
            TimelineView(.animation) { context in
                strip(phase: GlowBand.phase(at: context.date))
            }
        }
    }

    private func strip(phase: Double) -> some View {
        let gradient = LinearGradient(
            stops: GlowBand.stops(phase: phase, palette: palette),
            startPoint: .leading,
            endPoint: .trailing
        )
        let shape = NotchShape(
            topFlareRadius: NotchGeometry.flareRadius,
            bottomCornerRadius: bottomCornerRadius
        )

        return ZStack {
            // Bloom first, core over it: the halo is what makes it read as light
            // rather than as a drawn border.
            shape.stroke(gradient, lineWidth: 11).blur(radius: 7).opacity(0.75)
            shape.stroke(gradient, lineWidth: 5.5).blur(radius: 1.6)
            shape.stroke(gradient, lineWidth: 3).blur(radius: 0.4)
        }
        // The shape is the notch's, so it has to sit exactly where the notch is:
        // hanging from the top of the window, inside the margins.
        .padding(.horizontal, horizontalMargin)
        .padding(.bottom, bottomMargin)
        .allowsHitTesting(false)
    }

}

/// Renders the glow to PNGs, one per phase.
///
/// The signal is an animation on a window above the menu bar, so it cannot be
/// checked from the code and `screencapture` needs the Screen Recording
/// permission this machine does not grant. Each frame is composed the way the real
/// thing is layered — background, glow, then the panel's black over it — so what
/// the file shows is what the strip will look like, occlusion included.
@MainActor
enum NotchGlowFilmstrip {
    static func write(
        to directory: URL,
        notchSize: CGSize,
        bottomCornerRadius: CGFloat,
        palette: NotchGlowPalette,
        phases: [Double],
        name: String
    ) {
        let margin = NotchAuraWindow.margin
        for (index, phase) in phases.enumerated() {
            let frame = ZStack {
                // Stand-in for what is behind: a wallpaper, and the lighter strip
                // of the menu bar across the top.
                LinearGradient(
                    colors: [Color(white: 0.42), Color(white: 0.16)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(spacing: 0) {
                    Color.white.opacity(0.10).frame(height: 32)
                    Spacer(minLength: 0)
                }

                NotchGlowView(
                    palette: palette,
                    bottomCornerRadius: bottomCornerRadius,
                    horizontalMargin: margin,
                    bottomMargin: margin,
                    fixedPhase: phase
                )

                // The panel itself, which is what hides the inner half of the stroke.
                VStack(spacing: 0) {
                    NotchShape(
                        topFlareRadius: NotchGeometry.flareRadius,
                        bottomCornerRadius: bottomCornerRadius
                    )
                    .fill(Color.black)
                    .frame(width: notchSize.width, height: notchSize.height)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: notchSize.width + margin * 2, height: notchSize.height + margin)

            let renderer = ImageRenderer(content: frame)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:])
            else { continue }

            let url = directory.appendingPathComponent("glow-\(name)-\(index).png")
            try? data.write(to: url)
        }
        Log.info("Filmstrip glow «\(name)» scritto in \(directory.path)", category: .panel)
    }
}
