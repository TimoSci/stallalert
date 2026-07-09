import Foundation

/// Renders a wind direction compass with downwind arrow and historical direction ticks.
///
/// The compass uses **meteorological convention**: wind direction is the direction FROM which the wind
/// is coming (e.g., a northerly wind comes from the north). The downwind direction shown on the compass
/// is the direction TO which the wind is blowing — calculated as (fromDeg + 180)° normalized to [0, 360).
///
/// Historical direction samples fade out over time (opacity decreases linearly over 3600 seconds),
/// and samples older than 3600 seconds are dropped.
public struct CompassRender: Equatable, Sendable {
    public let arrowAngleDeg: Double
    public let ticks: [Tick]

    public struct Tick: Equatable, Sendable {
        public let angleDeg: Double
        public let opacity: Double

        public init(angleDeg: Double, opacity: Double) {
            self.angleDeg = angleDeg
            self.opacity = opacity
        }
    }

    public init(arrowAngleDeg: Double, ticks: [Tick]) {
        self.arrowAngleDeg = arrowAngleDeg
        self.ticks = ticks
    }
}

public enum CompassModel {
    public static func render(reading: StationReading, now: Date) -> CompassRender {
        // Calculate the downwind arrow direction
        let arrowAngleDeg = normalizeDownwind(reading.dirDeg)

        // Process historical direction samples
        var ticks: [CompassRender.Tick] = []

        if let history = reading.directionHistory {
            // Create a set of unique times (for deduplication), excluding the current reading time
            var seenTimes = Set<TimeInterval>()

            for sample in history {
                // Skip entries with the same time as the reading
                if sample.time == reading.time {
                    continue
                }

                // Skip if we've already seen this timestamp (deduplication)
                let timeInterval = sample.time.timeIntervalSince1970
                if seenTimes.contains(timeInterval) {
                    continue
                }
                seenTimes.insert(timeInterval)

                // Calculate age in seconds
                let age = now.timeIntervalSince(sample.time)

                // Skip samples older than or at 3600 seconds boundary
                if age >= 3600 {
                    continue
                }

                // Calculate opacity using linear fade: 0.6 * max(0, 1 - age/3600)
                let opacity = 0.6 * max(0, 1 - age / 3600)

                // Calculate downwind direction for this sample
                let tickAngleDeg = normalizeDownwind(sample.dirDeg)

                let tick = CompassRender.Tick(angleDeg: tickAngleDeg, opacity: opacity)
                ticks.append(tick)
            }
        }

        return CompassRender(arrowAngleDeg: arrowAngleDeg, ticks: ticks)
    }

    /// Normalizes a meteorological FROM-direction to a downwind TO-direction.
    /// Formula: (fromDeg + 180) % 360, with special handling for negative remainders.
    private static func normalizeDownwind(_ fromDeg: Double) -> Double {
        let downwind = (fromDeg + 180).truncatingRemainder(dividingBy: 360)
        return downwind < 0 ? downwind + 360 : downwind
    }
}
