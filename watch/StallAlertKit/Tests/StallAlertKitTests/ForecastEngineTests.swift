import XCTest
@testable import StallAlertKit

final class ForecastEngineTests: XCTestCase {
    private func step(_ hourOffset: Double, wind: Double, gust: Double) -> WindStep {
        WindStep(time: Date(timeIntervalSince1970: 1_000_000 + hourOffset * 3600),
                 windKn: wind, gustKn: gust, dirDeg: 225)
    }
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testDroppingWind() {
        let f = Forecast(model: "wg", initTime: t0,
                         hours: [step(0, wind: 14, gust: 21), step(1, wind: 11, gust: 17), step(2, wind: 9, gust: 14)])
        let v = ForecastEngine.nextHour(from: f, at: t0)!
        XCTAssertEqual(v.minKn, 11, accuracy: 0.01)   // base at now+1h
        XCTAssertEqual(v.maxKn, 21, accuracy: 0.01)   // gust at now
        XCTAssertEqual(v.trend, .dropping)
        XCTAssertEqual(v.projectedBaseKn, 11, accuracy: 0.01)
        XCTAssertEqual(v.samplesKn.count, 7)
        XCTAssertEqual(v.samplesKn.last!, v.projectedBaseKn, accuracy: 0.0001)
        XCTAssertEqual(v.samplesKn.min()!, v.minKn, accuracy: 0.0001)
    }

    func testSteadyWindWithinOneKnot() {
        let f = Forecast(model: "wg", initTime: t0,
                         hours: [step(0, wind: 14, gust: 20), step(1, wind: 14.5, gust: 21), step(2, wind: 14, gust: 20)])
        XCTAssertEqual(ForecastEngine.nextHour(from: f, at: t0)!.trend, .steady)
    }

    func testRisingWindInterpolatesBetweenSteps() {
        // now = halfway between step 0 and step 1 -> base now = 12, base in 1h = 15
        let f = Forecast(model: "wg", initTime: t0,
                         hours: [step(0, wind: 10, gust: 14), step(1, wind: 14, gust: 18), step(2, wind: 16, gust: 20)])
        let now = t0.addingTimeInterval(1800)
        let v = ForecastEngine.nextHour(from: f, at: now)!
        XCTAssertEqual(v.minKn, 12, accuracy: 0.01)
        XCTAssertEqual(v.projectedBaseKn, 15, accuracy: 0.01)
        XCTAssertEqual(v.trend, .rising)
    }

    func testThreeHourStepsInterpolate() {
        let f = Forecast(model: "gfs", initTime: t0,
                         hours: [step(0, wind: 15, gust: 20), step(3, wind: 9, gust: 13)])
        let v = ForecastEngine.nextHour(from: f, at: t0)!   // base in 1h = 13
        XCTAssertEqual(v.projectedBaseKn, 13, accuracy: 0.01)
        XCTAssertEqual(v.trend, .dropping)
    }

    func testOutsideTimelineReturnsNil() {
        let f = Forecast(model: "wg", initTime: t0, hours: [step(0, wind: 14, gust: 21)])
        XCTAssertNil(ForecastEngine.nextHour(from: f, at: t0))            // now+1h beyond last step
        XCTAssertNil(ForecastEngine.nextHour(from: f, at: t0.addingTimeInterval(-3600)))
        XCTAssertNil(ForecastEngine.nextHour(from: Forecast(model: "wg", initTime: t0, hours: []), at: t0))
    }

    func testDirDegConstantDirection() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let steps = [
            WindStep(time: now, windKn: 10, gustKn: 12, dirDeg: 90),
            WindStep(time: now.addingTimeInterval(3600), windKn: 10, gustKn: 12, dirDeg: 90),
        ]
        let nh = ForecastEngine.nextHour(from: Forecast(model: "t", initTime: now, hours: steps), at: now)!
        XCTAssertEqual(nh.dirDeg!, 90, accuracy: 0.0001)
    }

    func testDirDegNorthSeamAveragesToZero() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let steps = [
            WindStep(time: now, windKn: 10, gustKn: 12, dirDeg: 350),
            WindStep(time: now.addingTimeInterval(3600), windKn: 10, gustKn: 12, dirDeg: 10),
        ]
        let nh = ForecastEngine.nextHour(from: Forecast(model: "t", initTime: now, hours: steps), at: now)!
        let d = nh.dirDeg!
        // mean must sit at the seam (0°/360°), never anywhere near 180
        XCTAssertTrue(d < 0.1 || d > 359.9, "expected ~0, got \(d)")
    }

    func testDirDegOpposingDirectionsIsNil() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let steps = [
            WindStep(time: now, windKn: 10, gustKn: 12, dirDeg: 0),
            WindStep(time: now.addingTimeInterval(3600), windKn: 10, gustKn: 12, dirDeg: 180),
        ]
        let nh = ForecastEngine.nextHour(from: Forecast(model: "t", initTime: now, hours: steps), at: now)!
        // 0° and 180° in equal measure cancel: 3 samples each side of the
        // antipodal midpoint (which itself yields no vector) -> nil
        XCTAssertNil(nh.dirDeg)
    }
}
