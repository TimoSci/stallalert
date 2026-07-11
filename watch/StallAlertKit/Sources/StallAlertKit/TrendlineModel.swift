import Foundation

/// Normalizes the next-hour wind samples plus the alert threshold into
/// [0, 1] y-coordinates for the mini trendline. The range always includes
/// the threshold (so its reference line is in frame) and spans at least
/// 4 kn (so flat forecasts draw flat instead of amplifying sub-knot noise).
public struct TrendlineRender: Equatable, Sendable {
    public let ys: [Double]       // [0, 1], 0 = range bottom; one per sample
    public let thresholdY: Double // same space

    public init(ys: [Double], thresholdY: Double) {
        self.ys = ys
        self.thresholdY = thresholdY
    }
}

public enum TrendlineModel {
    /// nil when there are fewer than 2 samples (nothing to draw).
    public static func render(samplesKn: [Double], thresholdKn: Double) -> TrendlineRender? {
        guard samplesKn.count >= 2 else { return nil }
        var lo = min(samplesKn.min()!, thresholdKn)
        var hi = max(samplesKn.max()!, thresholdKn)
        if hi - lo < 4 {
            let mid = (hi + lo) / 2
            lo = mid - 2
            hi = mid + 2
        }
        let span = hi - lo
        return TrendlineRender(
            ys: samplesKn.map { ($0 - lo) / span },
            thresholdY: (thresholdKn - lo) / span
        )
    }
}
