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

    func testBackwardCompatibilityWithFixture() throws {
        let url = Bundle.module.url(forResource: "Fixtures/conditions", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let c = try Conditions.decoder().decode(Conditions.self, from: data)
        // Old fixture has no source or nearby_stations fields
        XCTAssertNil(c.station?.source)
        XCTAssertNil(c.nearbyStations)
    }

    func testDecodesSourceAndNearbyStations() throws {
        let json = """
        {"generated_at":"2026-07-06T10:00:00Z","stale":false,
         "forecast":{"model":"gfs-micro","init_time":"2026-07-06T06:00:00Z","hours":[]},
         "station":{"id":42,"name":"Main","distance_km":0.5,"reading":null,"source":"manual"},
         "nearby_stations":[
           {"id":1,"name":"TestStn","distance_km":1.2},
           {"id":2,"name":"Secondary","distance_km":2.5}
         ]}
        """.data(using: .utf8)!
        let c = try Conditions.decoder().decode(Conditions.self, from: json)
        XCTAssertEqual(c.station?.source, "manual")
        XCTAssertEqual(c.nearbyStations?.count, 2)
        XCTAssertEqual(c.nearbyStations?[0].id, 1)
        XCTAssertEqual(c.nearbyStations?[0].name, "TestStn")
        XCTAssertEqual(c.nearbyStations?[0].distanceKm, 1.2)
        XCTAssertEqual(c.nearbyStations?[1].id, 2)
        XCTAssertEqual(c.nearbyStations?[1].name, "Secondary")
        XCTAssertEqual(c.nearbyStations?[1].distanceKm, 2.5)
    }

    func testExistingFixtureHasNoDirectionHistory() throws {
        let url = Bundle.module.url(forResource: "Fixtures/conditions", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let c = try Conditions.decoder().decode(Conditions.self, from: data)
        XCTAssertNil(c.station?.reading?.directionHistory)
    }

    func testDecodesDirectionHistory() throws {
        let json = """
        {"generated_at":"2026-07-06T10:00:00Z","stale":false,
         "forecast":{"model":"gfs-micro","init_time":"2026-07-06T06:00:00Z","hours":[]},
         "station":{"id":42,"name":"Main","distance_km":0.5,"reading":
           {"time":"2026-07-06T10:00:00Z","wind_kn":10.0,"gust_kn":15.0,"dir_deg":180.0,
            "direction_history":[
              {"time":"2026-07-06T09:50:00Z","dir_deg":175.0},
              {"time":"2026-07-06T09:55:00Z","dir_deg":178.0}
            ]}}}
        """.data(using: .utf8)!
        let c = try Conditions.decoder().decode(Conditions.self, from: json)
        XCTAssertNotNil(c.station?.reading?.directionHistory)
        XCTAssertEqual(c.station?.reading?.directionHistory?.count, 2)
        XCTAssertEqual(c.station?.reading?.directionHistory?[0].dirDeg, 175.0)
        XCTAssertEqual(c.station?.reading?.directionHistory?[0].time, Date(timeIntervalSince1970: 1783331400))
        XCTAssertEqual(c.station?.reading?.directionHistory?[1].dirDeg, 178.0)
        XCTAssertEqual(c.station?.reading?.directionHistory?[1].time, Date(timeIntervalSince1970: 1783331700))
    }
}
