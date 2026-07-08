import Foundation

public enum Trend: Equatable, Sendable { case rising, steady, dropping }

public struct NextHourView: Equatable, Sendable {
    public let minKn: Double
    public let maxKn: Double
    public let trend: Trend
    public let projectedBaseKn: Double
    public init(minKn: Double, maxKn: Double, trend: Trend, projectedBaseKn: Double) {
        self.minKn = minKn; self.maxKn = maxKn; self.trend = trend; self.projectedBaseKn = projectedBaseKn
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
        return NextHourView(minKn: bases.min()!, maxKn: gusts.max()!, trend: trend, projectedBaseKn: baseNext)
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
}
