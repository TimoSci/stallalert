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
}
