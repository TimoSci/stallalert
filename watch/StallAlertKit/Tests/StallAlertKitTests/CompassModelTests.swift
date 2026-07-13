import XCTest
@testable import StallAlertKit

final class CompassModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testDownwindWraparound() {
        // dirDeg 350 -> arrow 170 (350 + 180 = 530, 530 % 360 = 170)
        var reading = StationReading(time: t0, windKn: 10, gustKn: 15, dirDeg: 350)
        var render = CompassModel.render(reading: reading, now: t0)
        XCTAssertEqual(render.arrowAngleDeg, 170, accuracy: 0.001)

        // dirDeg 90 -> arrow 270 (90 + 180 = 270)
        reading = StationReading(time: t0, windKn: 10, gustKn: 15, dirDeg: 90)
        render = CompassModel.render(reading: reading, now: t0)
        XCTAssertEqual(render.arrowAngleDeg, 270, accuracy: 0.001)

        // dirDeg 180 -> arrow 0 (180 + 180 = 360, 360 % 360 = 0)
        reading = StationReading(time: t0, windKn: 10, gustKn: 15, dirDeg: 180)
        render = CompassModel.render(reading: reading, now: t0)
        XCTAssertEqual(render.arrowAngleDeg, 0, accuracy: 0.001)
    }

    func testTickOpacityFade() {
        // Sample 0s old (but time != reading.time) -> opacity 0.6
        let history1 = DirectionSample(time: t0.addingTimeInterval(-1), dirDeg: 90)
        var reading = StationReading(time: t0, windKn: 10, gustKn: 15, dirDeg: 180, directionHistory: [history1])
        var render = CompassModel.render(reading: reading, now: t0)
        XCTAssertEqual(render.ticks.count, 1)
        XCTAssertEqual(render.ticks[0].opacity, 0.6, accuracy: 0.001)

        // 1800s -> opacity 0.3
        let history2 = DirectionSample(time: t0.addingTimeInterval(-1800), dirDeg: 90)
        reading = StationReading(time: t0, windKn: 10, gustKn: 15, dirDeg: 180, directionHistory: [history2])
        render = CompassModel.render(reading: reading, now: t0)
        XCTAssertEqual(render.ticks.count, 1)
        XCTAssertEqual(render.ticks[0].opacity, 0.3, accuracy: 0.001)

        // 3599s -> opacity ~0.0002 (still present)
        let history3 = DirectionSample(time: t0.addingTimeInterval(-3599), dirDeg: 90)
        reading = StationReading(time: t0, windKn: 10, gustKn: 15, dirDeg: 180, directionHistory: [history3])
        render = CompassModel.render(reading: reading, now: t0)
        XCTAssertEqual(render.ticks.count, 1)
        XCTAssertEqual(render.ticks[0].opacity, 0.0002, accuracy: 0.0001)

        // 3601s -> dropped
        let history4 = DirectionSample(time: t0.addingTimeInterval(-3601), dirDeg: 90)
        reading = StationReading(time: t0, windKn: 10, gustKn: 15, dirDeg: 180, directionHistory: [history4])
        render = CompassModel.render(reading: reading, now: t0)
        XCTAssertEqual(render.ticks.count, 0)
    }

    func testCurrentReadingExcluded() {
        // History entry with time == reading.time produces NO tick
        let history = DirectionSample(time: t0, dirDeg: 90)
        let reading = StationReading(time: t0, windKn: 10, gustKn: 15, dirDeg: 180, directionHistory: [history])
        let render = CompassModel.render(reading: reading, now: t0)
        XCTAssertEqual(render.ticks.count, 0)
    }

    func testDuplicateTimestampsDeduped() {
        // Two entries with same time -> one tick
        let history1 = DirectionSample(time: t0.addingTimeInterval(-100), dirDeg: 90)
        let history2 = DirectionSample(time: t0.addingTimeInterval(-100), dirDeg: 95)
        let reading = StationReading(time: t0, windKn: 10, gustKn: 15, dirDeg: 180, directionHistory: [history1, history2])
        let render = CompassModel.render(reading: reading, now: t0)
        XCTAssertEqual(render.ticks.count, 1)
    }

    func testNilHistoryMeansNoTicks() {
        // directionHistory nil -> ticks == []
        let reading = StationReading(time: t0, windKn: 10, gustKn: 15, dirDeg: 180, directionHistory: nil)
        let render = CompassModel.render(reading: reading, now: t0)
        XCTAssertEqual(render.ticks.count, 0)
    }

    func testExactHourBoundaryDropped() {
        // Sample at exactly 3600s age -> NO tick emitted
        // (opacity would be 0.6 * (1 - 3600/3600) = 0, violating invariant)
        let history = DirectionSample(time: t0.addingTimeInterval(-3600), dirDeg: 90)
        let reading = StationReading(time: t0, windKn: 10, gustKn: 15, dirDeg: 180, directionHistory: [history])
        let render = CompassModel.render(reading: reading, now: t0)
        XCTAssertEqual(render.ticks.count, 0)
    }

    func testDedupeFirstOccurrenceWins() {
        // Two samples with same time but different dirDeg -> first sample's angle used
        // First sample: dirDeg 100 -> downwind 280
        // Second sample: dirDeg 200 -> downwind 20 (ignored due to dedup)
        let time = t0.addingTimeInterval(-100)
        let history1 = DirectionSample(time: time, dirDeg: 100)
        let history2 = DirectionSample(time: time, dirDeg: 200)
        let reading = StationReading(time: t0, windKn: 10, gustKn: 15, dirDeg: 180, directionHistory: [history1, history2])
        let render = CompassModel.render(reading: reading, now: t0)
        XCTAssertEqual(render.ticks.count, 1)
        XCTAssertEqual(render.ticks[0].angleDeg, 280, accuracy: 0.001)
    }

    func testNegativeDirectionNormalizes() {
        // dirDeg -10 -> arrow 170 ((-10 + 180) % 360 = 170)
        let reading = StationReading(time: t0, windKn: 10, gustKn: 15, dirDeg: -10)
        let render = CompassModel.render(reading: reading, now: t0)
        XCTAssertEqual(render.arrowAngleDeg, 170, accuracy: 0.001)
    }

    func testDownwindAngleWraparound() {
        XCTAssertEqual(CompassModel.downwindAngle(fromDeg: 350), 170)
        XCTAssertEqual(CompassModel.downwindAngle(fromDeg: 90), 270)
        XCTAssertEqual(CompassModel.downwindAngle(fromDeg: 180), 0)
        XCTAssertEqual(CompassModel.downwindAngle(fromDeg: 0), 180)
    }
}
