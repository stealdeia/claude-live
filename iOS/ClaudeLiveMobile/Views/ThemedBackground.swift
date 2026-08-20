import SwiftUI
import ClaudeLiveKit

/// The background: black at the top, colour at the bottom, and not a straight
/// line between them.
///
/// Built with `MeshGradient` rather than a `LinearGradient` because the brief was
/// a fade that is "wavy and a bit unusual", and a linear one cannot be: it is by
/// definition the same at every point along a line. A mesh has interior control
/// points, and pulling them off the grid is what makes the colour arrive earlier
/// on one side than the other — read as a wave rather than a ramp.
///
/// The top row is pure black in every theme, and that is a functional choice
/// rather than a stylistic one: it meets the Dynamic Island and stops the phone's
/// hardware and the app from being two separate things.
///
/// Requires iOS 18, which is why the app asks for it.
struct ThemedBackground: View {
    @Environment(\.theme) private var theme
    /// Very slow drift. Off by default: it is beautiful for ten seconds and
    /// distracting for an hour, and this is an app you glance at.
    var animated: Bool = false

    @State private var phase: Double = 0

    var body: some View {
        MeshGradient(
            width: 3,
            height: 4,
            points: points,
            colors: [
                theme.top, theme.top, theme.top,
                theme.top, theme.bloom.opacity(0.55), theme.top,
                theme.deep.opacity(0.75), theme.bloom, theme.deep.opacity(0.85),
                theme.deep, theme.deep, theme.deep,
            ],
            smoothsColors: true
        )
        .ignoresSafeArea()
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    /// A 3×4 grid. The outer columns stay pinned to the edges so no seam can
    /// appear; only the interior points move, which is where the wave comes from.
    private var points: [SIMD2<Float>] {
        let drift = Float(phase) * 0.06
        return [
            .init(0.0, 0.0), .init(0.5, 0.0), .init(1.0, 0.0),

            // Second row tilted: the colour reaches further down on the right.
            .init(0.0, 0.34), .init(0.62 + drift, 0.26), .init(1.0, 0.40),

            // Third row tilted the other way, which is what turns a slope into
            // an S rather than a diagonal.
            .init(0.0, 0.70), .init(0.36 - drift, 0.74), .init(1.0, 0.63),

            .init(0.0, 1.0), .init(0.5, 1.0), .init(1.0, 1.0),
        ]
    }
}

/// A panel that sits on the gradient without hiding it.
///
/// Translucent rather than filled: an opaque card on a coloured background
/// reintroduces exactly the flat rectangles the gradient exists to avoid.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white.opacity(0.07))
                    .background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            }
    }
}

#Preview("Temi") {
    ScrollView(.horizontal) {
        HStack(spacing: 0) {
            ForEach(ColorTheme.all) { theme in
                ZStack {
                    ThemedBackground()
                        .environment(\.theme, theme)
                    VStack {
                        Spacer()
                        GlassCard {
                            Text(theme.name)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                        }
                        .padding()
                    }
                }
                .frame(width: 260, height: 560)
            }
        }
    }
}
