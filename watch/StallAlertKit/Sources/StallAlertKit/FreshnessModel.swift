import Foundation

/// Freshness of the displayed station reading, keyed purely off the
/// reading's own timestamp: a newer sample lowers the age, which IS the
/// "reset on update" — no stored fetch state (spec 2026-07-10, Decisions).
public struct FreshnessRender: Equatable, Sendable {
    public let greenness: Double       // [0, 1]; 1 = brand-new reading
    public let markerFraction: Double  // [0, 1]; position along the track
    public let showClock: Bool         // marker replaced by clock symbol

    public init(greenness: Double, markerFraction: Double, showClock: Bool) {
        self.greenness = greenness
        self.markerFraction = markerFraction
        self.showClock = showClock
    }
}

public enum FreshnessModel {
    /// Negative ages (reading timestamp ahead of `now` — clock skew)
    /// clamp to 0: full green, marker at the start.
    public static func render(readingTime: Date, now: Date) -> FreshnessRender {
        let age = max(0, now.timeIntervalSince(readingTime))
        return FreshnessRender(
            greenness: max(0, 1 - age / 300),
            markerFraction: min(age / 900, 1),
            showClock: age >= 900
        )
    }
}
