import XCTest
@testable import StallAlertKit

final class ModelsTests: XCTestCase {
    func testDecodesServerConditionsPayload() throws {
        let url = Bundle.module.url(forResource: "Fixtures/conditions", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let c = try Conditions.decoder().decode(Conditions.self, from: data)
        XCTAssertFalse(c.stale)
        XCTAssertEqual(c.forecast.model, "GFS 13 km")
        XCTAssertEqual(c.forecast.hours.count, 3)
        XCTAssertEqual(c.forecast.hours[0].windKn, 14.0)
        XCTAssertEqual(c.station?.name, "Ijburg")
        XCTAssertEqual(c.station?.reading?.windKn, 15.5)
    }

    func testStationIsOptional() throws {
        let json = """
        {"generated_at":"2026-07-06T10:00:00Z","stale":true,
         "forecast":{"model":"gfs-micro","init_time":"2026-07-06T06:00:00Z","hours":[]},
         "station":null}
        """.data(using: .utf8)!
        let c = try Conditions.decoder().decode(Conditions.self, from: json)
        XCTAssertNil(c.station)
        XCTAssertTrue(c.stale)
    }
}
