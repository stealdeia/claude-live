import SwiftUI
import ClaudeLiveKit

/// A usage window drawn as a ring: the label sits in the middle, the stroke fills
/// clockwise with the utilisation and takes the threshold colour.
///
/// This is the compact form used in the notch strips, where horizontal space is
/// the scarce resource — a ring carries the same information as "5h 11%" in a
/// third of the width. The exact percentage lives in the expanded panel.
struct UsageRing: View {
    let window: UsageWindow?
    let label: String
    let warn: Double
    let danger: Double

    var diameter: CGFloat = NotchGeometry.baseRingDiameter
    /// Derived from the diameter so the scale setting moves stroke and label
    /// together and the ring keeps its proportions.
    private var lineWidth: CGFloat { max(2, diameter * 0.12) }
    private var labelSize: CGFloat { diameter * 0.40 }
    /// Track colour; the default suits the black notch background.
    var trackColor: Color = Color.white.opacity(0.20)
    var labelColor: Color = .white

    private var fraction: Double {
        (window?.utilization ?? 0).clamped(to: 0...1)
    }

    private var color: Color {
        guard window != nil else { return trackColor }
        return PanelTheme.color(
            for: UsageLevel.level(for: fraction, warn: warn, danger: danger)
        )
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)

            Circle()
                // A hairline arc for a non-zero-but-tiny value reads better than
                // nothing at all.
                .trim(from: 0, to: fraction > 0 ? max(fraction, 0.02) : 0)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // Start at 12 o'clock rather than 3.
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)

            Text(label)
                .font(.system(size: labelSize, weight: .semibold))
                .foregroundStyle(window == nil ? labelColor.opacity(0.4) : labelColor.opacity(0.85))
        }
        .frame(width: diameter, height: diameter)
    }
}
