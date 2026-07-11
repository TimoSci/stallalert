import XCTest
@testable import StallAlertKit

final class TrendlineModelTests: XCTestCase {
    func testThresholdBelowSamples() {
        let r = TrendlineModel.render(samplesKn: [10, 12], thresholdKn: 8)!
        XCTAssertEqual(r.ys, [0.5, 1.0])
        XCTAssertEqual(r.thresholdY, 0.0)
    }

    func testThresholdAboveSamplesStaysInFrame() {
        let r = TrendlineModel.render(samplesKn: [10, 12], thresholdKn: 15)!
        XCTAssertEqual(r.thresholdY, 1.0)
        XCTAssertEqual(r.ys[0], 0.0)
        XCTAssertEqual(r.ys[1], 0.4, accuracy: 0.0001)
    }

    func testMinimumSpanExpansion() {
        // natural span 1 kn -> expanded to 4 around midpoint 10.5 (8.5...12.5)
        let r = TrendlineModel.render(samplesKn: [10, 11], thresholdKn: 10.5)!
        XCTAssertEqual(r.ys[0], 0.375, accuracy: 0.0001)
        XCTAssertEqual(r.ys[1], 0.625, accuracy: 0.0001)
        XCTAssertEqual(r.thresholdY, 0.5, accuracy: 0.0001)
    }

    func testSamplesSpanningThreshold() {
        let r = TrendlineModel.render(samplesKn: [6, 12], thresholdKn: 9)!
        XCTAssertEqual(r.thresholdY, 0.5, accuracy: 0.0001)
        XCTAssertEqual(r.ys, [0.0, 1.0])
    }

    func testTooFewSamplesReturnsNil() {
        XCTAssertNil(TrendlineModel.render(samplesKn: [], thresholdKn: 10))
        XCTAssertNil(TrendlineModel.render(samplesKn: [10], thresholdKn: 10))
    }
}
