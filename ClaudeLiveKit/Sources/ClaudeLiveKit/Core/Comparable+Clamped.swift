import Foundation

extension Comparable {
    /// Keeps a value inside a range. Used for percentages, opacities and the
    /// settings' numeric bounds, and needed on both platforms.
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
