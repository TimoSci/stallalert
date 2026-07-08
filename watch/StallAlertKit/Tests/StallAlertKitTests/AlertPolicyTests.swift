// watch/StallAlertKit/Tests/StallAlertKitTests/AlertPolicyTests.swift
import XCTest
@testable import StallAlertKit

final class AlertPolicyTests: XCTestCase {
    private func input(forecast: Double?, live: Double? = nil, age: TimeInterval? = 60) -> AlertPolicy.Input {
        .init(forecastMinKn: forecast, liveKn: live, liveAgeSeconds: live == nil ? nil : age)
    }

    func testFiresPredictedWhenForecastMinBelowThreshold() {
        var p = AlertPolicy(thresholdKn: 12)
        XCTAssertEqual(p.evaluate(input(forecast: 11, live: 15)), .predicted)
    }

    func testMeasuredTakesPriorityOverPredicted() {
        var p = AlertPolicy(thresholdKn: 12)
        XCTAssertEqual(p.evaluate(input(forecast: 11, live: 10)), .measured)
    }

    func testDoesNotRefireWhileBelowThreshold() {
        var p = AlertPolicy(thresholdKn: 12)
        XCTAssertEqual(p.evaluate(input(forecast: 11)), .predicted)
        XCTAssertNil(p.evaluate(input(forecast: 10)))
        XCTAssertNil(p.evaluate(input(forecast: 11.9)))
    }

    func testRearmsOnlyAfterRecoveryAboveThresholdPlusHysteresis() {
        var p = AlertPolicy(thresholdKn: 12)
        XCTAssertEqual(p.evaluate(input(forecast: 11)), .predicted)
        XCTAssertNil(p.evaluate(input(forecast: 13)))   // above threshold but within hysteresis
        XCTAssertNil(p.evaluate(input(forecast: 11)))   // drop again -> still silenced
        XCTAssertNil(p.evaluate(input(forecast: 14.5))) // >= 14 -> re-arms, no fire
        XCTAssertEqual(p.evaluate(input(forecast: 11)), .predicted) // new event fires
    }

    func testStaleLiveReadingIsIgnored() {
        var p = AlertPolicy(thresholdKn: 12)
        // live 8 kn but 25 min old -> ignored; forecast fine -> no alert
        XCTAssertNil(p.evaluate(input(forecast: 15, live: 8, age: 25 * 60)))
        // fresh live 8 kn -> measured
        XCTAssertEqual(p.evaluate(input(forecast: 15, live: 8, age: 60)), .measured)
    }

    func testNoDataNeverFiresOrRearms() {
        var p = AlertPolicy(thresholdKn: 12)
        XCTAssertNil(p.evaluate(input(forecast: nil)))
        XCTAssertEqual(p.evaluate(input(forecast: 11)), .predicted)
        XCTAssertNil(p.evaluate(input(forecast: nil))) // silence persists through data gaps
        XCTAssertNil(p.evaluate(input(forecast: 11)))
    }

    func testRearmRequiresAllChannelsAboveHysteresis() {
        var p = AlertPolicy(thresholdKn: 12)
        // Fire on forecast 11 (below threshold)
        XCTAssertEqual(p.evaluate(input(forecast: 11, live: 15)), .predicted)
        // live 14, forecast 13: not all above 14, so still silenced
        XCTAssertNil(p.evaluate(input(forecast: 13, live: 14)))
        // drop forecast to 11, live still 14: still not re-armed
        XCTAssertNil(p.evaluate(input(forecast: 11, live: 14)))
        // both 14: re-arm silently
        XCTAssertNil(p.evaluate(input(forecast: 14, live: 14)))
        // now forecast drops below, re-fire
        XCTAssertEqual(p.evaluate(input(forecast: 11, live: 15)), .predicted)
    }

    func testExactBoundaryValues() {
        var p = AlertPolicy(thresholdKn: 12)
        // live exactly 12.0 doesn't fire (strict <)
        XCTAssertNil(p.evaluate(input(forecast: 15, live: 12.0)))
        // forecast exactly 12.0 with no live doesn't fire
        XCTAssertNil(p.evaluate(input(forecast: 12.0)))
        // forecast 11 fires
        XCTAssertEqual(p.evaluate(input(forecast: 11)), .predicted)
        // forecast 14.0 re-arms silently (inclusive >=)
        XCTAssertNil(p.evaluate(input(forecast: 14.0)))
        // forecast 11 fires again
        XCTAssertEqual(p.evaluate(input(forecast: 11)), .predicted)
    }

    func testLiveReadingWithoutAgeIsExcluded() {
        var p = AlertPolicy(thresholdKn: 12)
        // live 5 with unknown age is excluded; forecast 15 is fine -> no fire
        let inputUnknownAge = AlertPolicy.Input(forecastMinKn: 15, liveKn: 5, liveAgeSeconds: nil)
        XCTAssertNil(p.evaluate(inputUnknownAge))
    }

    func testSilencedByPredictedStaysSilentWhenMeasuredAlsoDrops() {
        var p = AlertPolicy(thresholdKn: 12)
        // Fire on forecast 11
        XCTAssertEqual(p.evaluate(input(forecast: 11)), .predicted)
        // measured drops to 9, but already silenced -> no second fire
        XCTAssertNil(p.evaluate(input(forecast: 11, live: 9)))
    }
}
