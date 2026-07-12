import Foundation

public enum Trend: Equatable, Sendable { case rising, steady, dropping }

public struct NextHourView: Equatable, Sendable {
    public let minKn: Double
    public let maxKn: Double
    public let trend: Trend
    public let projectedBaseKn: Double
    public let samplesKn: [Double]
    public let dirDeg: Double?
    public init(minKn: Double, maxKn: Double, trend: Trend, projectedBaseKn: Double,
                samplesKn: [Double] = [], dirDeg: Double? = nil) {
        self.minKn = minKn; self.maxKn = maxKn; self.trend = trend
        self.projectedBaseKn = projectedBaseKn; self.samplesKn = samplesKn
        self.dirDeg = dirDeg
    }
}

public enum ForecastEngine {
    public static func nextHour(from forecast: Forecast, at now: Date) -> NextHourView? {
        let steps = forecast.hours.sorted { $0.time < $1.time }
        // Sample base wind and gusts every 10 min across [now, now+1h].
        let samples = stride(from: 0.0, through: 3600, by: 600).map { now.addingTimeInterval($0) }
        var bases: [Double] = [], gusts: [Double] = []
        for t in samples {
            guard let b = interpolate(steps, at: t, value: { $0.windKn }),
                  let g = interpolate(steps, at: t, value: { $0.gustKn }) else { return nil }
            bases.append(b); gusts.append(g)
        }
        let baseNow = bases.first!, baseNext = bases.last!
        let delta = baseNext - baseNow
        let trend: Trend = delta > 1 ? .rising : (delta < -1 ? .dropping : .steady)

        // Vector-mean forecast direction over the same window (seam-safe);
        // samples whose interpolation is antipodal-degenerate are skipped,
        // and a near-zero resultant (genuinely turning wind) yields nil.
        var vx = 0.0, vy = 0.0
        for t in samples {
            if let d = interpolateDirection(steps, at: t) {
                vx += sin(d * .pi / 180)
                vy += cos(d * .pi / 180)
            }
        }
        let dirDeg: Double?
        if (vx * vx + vy * vy).squareRoot() < 1.0e-9 {
            dirDeg = nil
        } else {
            var deg = atan2(vx, vy) * 180 / .pi
            if deg < 0 { deg += 360 }
            dirDeg = deg
        }
        return NextHourView(minKn: bases.min()!, maxKn: gusts.max()!, trend: trend,
                            projectedBaseKn: baseNext, samplesKn: bases, dirDeg: dirDeg)
    }

    private static func interpolate(_ steps: [WindStep], at t: Date, value: (WindStep) -> Double) -> Double? {
        guard let first = steps.first, let last = steps.last,
              t >= first.time, t <= last.time else { return nil }
        if let exact = steps.first(where: { $0.time == t }) { return value(exact) }
        guard let after = steps.first(where: { $0.time > t }),
              let before = steps.last(where: { $0.time < t }) else { return nil }
        let span = after.time.timeIntervalSince(before.time)
        let frac = t.timeIntervalSince(before.time) / span
        return value(before) + (value(after) - value(before)) * frac
    }

    /// Direction interpolation must be vectorial: lerping raw degrees breaks
    /// at the north seam (350 -> 10 would pass through 180). Lerp the unit
    /// vectors by the same time fraction instead; an antipodal midpoint has
    /// no defined direction and returns nil (the sample is skipped).
    private static func interpolateDirection(_ steps: [WindStep], at t: Date) -> Double? {
        guard let first = steps.first, let last = steps.last,
              t >= first.time, t <= last.time else { return nil }
        if let exact = steps.first(where: { $0.time == t }) { return exact.dirDeg }
        guard let after = steps.first(where: { $0.time > t }),
              let before = steps.last(where: { $0.time < t }) else { return nil }
        let span = after.time.timeIntervalSince(before.time)
        let frac = t.timeIntervalSince(before.time) / span
        let b = before.dirDeg * .pi / 180, a = after.dirDeg * .pi / 180
        let x = sin(b) * (1 - frac) + sin(a) * frac
        let y = cos(b) * (1 - frac) + cos(a) * frac
        guard x * x + y * y > 1.0e-18 else { return nil }
        var deg = atan2(x, y) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }
}
