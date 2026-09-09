import SwiftUI
import ClaudeLiveKit

/// All visual constants in one place. The panel views read only from here and
/// from the view models — never from AppKit — so the same views can later be
/// hosted in a notch surface with different metrics.
enum PanelTheme {
    // MARK: Metrics

    static let expandedWidth: CGFloat = 268
    static let collapsedWidth: CGFloat = 168
    static let collapsedHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 14
    static let collapsedCornerRadius: CGFloat = 9
    static let contentPadding: CGFloat = 12
    static let screenMargin: CGFloat = 12
    static let barHeight: CGFloat = 6

    // MARK: Colours

    static func color(for level: UsageLevel) -> Color {
        switch level {
        case .normal: return Color(red: 0.24, green: 0.78, blue: 0.44)
        case .warning: return Color(red: 0.98, green: 0.75, blue: 0.18)
        case .danger: return Color(red: 0.96, green: 0.31, blue: 0.29)
        }
    }

    static let barTrack = Color.primary.opacity(0.12)
    static let secondaryText = Color.secondary
    static let separator = Color.primary.opacity(0.10)

    // MARK: Fonts

    static let titleFont = Font.system(size: 12, weight: .semibold)
    static let labelFont = Font.system(size: 11.5, weight: .medium)
    static let valueFont = Font.system(size: 13, weight: .semibold).monospacedDigit()
    static let captionFont = Font.system(size: 10.5, weight: .regular).monospacedDigit()
}

/// Whether the panel's detail is actually on screen.
///
/// The collapsed notch builds the whole expanded panel and hides it — opacity 0
/// inside a clip — because keeping the content at its full size is what stops the
/// layout from depending on a window that is mid-animation. The cost is that
/// everything in there goes on *running*: a repeating SwiftUI animation drives the
/// view graph on every display cycle whether or not anyone can see the result, and
/// the whole hosting view is laid out again each time.
///
/// Measured on 2026-09-09: the pulsing status dots alone, invisible behind a
/// collapsed notch, held the app at ~24% of a core. With them still the same app
/// sat at 1.1%. So anything in the detail that animates by itself reads this first.
///
/// Defaults to true: the floating panel has no hidden state to speak of, and a
/// view that forgets to be told is better left animating than left frozen.
private struct PanelContentIsVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var panelContentIsVisible: Bool {
        get { self[PanelContentIsVisibleKey.self] }
        set { self[PanelContentIsVisibleKey.self] = newValue }
    }
}
