import XCTest
@testable import StallAlertKit

final class FreshnessModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func render(age: TimeInterval) -> FreshnessRender {
        FreshnessModel.render(readingTime: t0, now: t0.addingTimeInterval(age))
    }

    func testBrandNewReading() {
        let f = render(age: 0)
        XCTAssertEqual(f.greenness, 1.0)
        XCTAssertEqual(f.markerFraction, 0.0)
        XCTAssertFalse(f.showClock)
    }

    func testHalfFadedAt150Seconds() {
        let f = render(age: 150)
        XCTAssertEqual(f.greenness, 0.5, accuracy: 0.0001)
        XCTAssertEqual(f.markerFraction, 150.0 / 900.0, accuracy: 0.0001)
        XCTAssertFalse(f.showClock)
    }

    func testFullyGrayAtFiveMinutes() {
        XCTAssertEqual(render(age: 300).greenness, 0.0)
        XCTAssertEqual(render(age: 400).greenness, 0.0) // clamped, not negative
    }

    func testJustBeforeClock() {
        let f = render(age: 899)
        XCTAssertFalse(f.showClock)
        XCTAssertLessThan(f.markerFraction, 1.0)
    }

    func testClockAtFifteenMinutes() {
        let f = render(age: 900)
        XCTAssertTrue(f.showClock)
        XCTAssertEqual(f.markerFraction, 1.0)
        XCTAssertEqual(f.greenness, 0.0)
    }

    func testMarkerCappedPastFifteenMinutes() {
        let f = render(age: 1800)
        XCTAssertTrue(f.showClock)
        XCTAssertEqual(f.markerFraction, 1.0)
    }

    func testFutureReadingClampsToZeroAge() {
        let f = render(age: -60) // clock skew: reading timestamp ahead of now
        XCTAssertEqual(f, render(age: 0))
    }
}
