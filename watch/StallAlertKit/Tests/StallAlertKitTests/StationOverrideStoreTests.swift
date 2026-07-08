import XCTest
@testable import StallAlertKit

final class StationOverrideStoreTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        UserDefaults(suiteName: #function)?.removePersistentDomain(forName: #function)
    }

    // MARK: - 1. No override by default

    func testNoOverrideByDefault() {
        let store = StationOverrideStore(defaults: UserDefaults(suiteName: #function)!)
        let override = store.override(nearLat: 39.92, lon: 3.09)
        XCTAssertNil(override)
    }

    // MARK: - 2. Set and lookup within 5 km

    func testSetAndLookupWithin5km() {
        let defaults = UserDefaults(suiteName: #function)!
        let store = StationOverrideStore(defaults: defaults)

        let entry = StationOverride(lat: 39.92, lon: 3.09, stationID: 123, stationName: "Test Station")
        store.set(entry)

        // Lookup at ~1.4 km away (0.01° lat + 0.01° lon)
        let found = store.override(nearLat: 39.93, lon: 3.10)
        XCTAssertEqual(found?.stationID, 123)
        XCTAssertEqual(found?.stationName, "Test Station")
    }

    // MARK: - 3. No match beyond 5 km

    func testNoMatchBeyond5km() {
        let defaults = UserDefaults(suiteName: #function)!
        let store = StationOverrideStore(defaults: defaults)

        let entry = StationOverride(lat: 39.92, lon: 3.09, stationID: 123, stationName: "Test Station")
        store.set(entry)

        // Lookup at ~5.6 km away (0.05° lat)
        let found = store.override(nearLat: 39.97, lon: 3.09)
        XCTAssertNil(found)
    }

    // MARK: - 4. Set within 5 km replaces

    func testSetWithin5kmReplaces() {
        let defaults = UserDefaults(suiteName: #function)!
        let store = StationOverrideStore(defaults: defaults)

        let entryA = StationOverride(lat: 39.92, lon: 3.09, stationID: 100, stationName: "Station A")
        store.set(entryA)

        // Set another entry ~1 km away (0.009° lat ≈ 1 km)
        let entryB = StationOverride(lat: 39.929, lon: 3.09, stationID: 200, stationName: "Station B")
        store.set(entryB)

        // Should have only one entry (B replaced A)
        let found = store.override(nearLat: 39.92, lon: 3.09)
        XCTAssertEqual(found?.stationID, 200)
        XCTAssertEqual(found?.stationName, "Station B")
    }

    // MARK: - 5. Two spots coexist

    func testTwoSpotsCoexist() {
        let defaults = UserDefaults(suiteName: #function)!
        let store = StationOverrideStore(defaults: defaults)

        // Mallorca location
        let mallorca = StationOverride(lat: 39.858276, lon: 3.101116, stationID: 1000, stationName: "Mallorca")
        store.set(mallorca)

        // Barcelona location (far enough to not replace Mallorca)
        let barcelona = StationOverride(lat: 52.36, lon: 5.04, stationID: 2000, stationName: "Barcelona")
        store.set(barcelona)

        // Lookup near Mallorca
        let nearMallorca = store.override(nearLat: 39.86, lon: 3.10)
        XCTAssertEqual(nearMallorca?.stationID, 1000)
        XCTAssertEqual(nearMallorca?.stationName, "Mallorca")

        // Lookup near Barcelona
        let nearBarcelona = store.override(nearLat: 52.35, lon: 5.05)
        XCTAssertEqual(nearBarcelona?.stationID, 2000)
        XCTAssertEqual(nearBarcelona?.stationName, "Barcelona")
    }

    // MARK: - 6. Clear near removes only that spot

    func testClearNearRemovesOnlyThatSpot() {
        let defaults = UserDefaults(suiteName: #function)!
        let store = StationOverrideStore(defaults: defaults)

        let mallorca = StationOverride(lat: 39.858276, lon: 3.101116, stationID: 1000, stationName: "Mallorca")
        store.set(mallorca)

        let barcelona = StationOverride(lat: 52.36, lon: 5.04, stationID: 2000, stationName: "Barcelona")
        store.set(barcelona)

        // Clear near Mallorca
        store.clearNear(lat: 39.858276, lon: 3.101116)

        // Mallorca should be gone
        let nearMallorca = store.override(nearLat: 39.86, lon: 3.10)
        XCTAssertNil(nearMallorca)

        // Barcelona should still be there
        let nearBarcelona = store.override(nearLat: 52.35, lon: 5.05)
        XCTAssertEqual(nearBarcelona?.stationID, 2000)
        XCTAssertEqual(nearBarcelona?.stationName, "Barcelona")
    }

    // MARK: - 7. Persistence across instances

    func testPersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: #function)!
        let store1 = StationOverrideStore(defaults: defaults)

        let entry = StationOverride(lat: 39.92, lon: 3.09, stationID: 789, stationName: "Persisted")
        store1.set(entry)

        // Create a new store instance with the same defaults
        let store2 = StationOverrideStore(defaults: defaults)
        let found = store2.override(nearLat: 39.92, lon: 3.09)

        XCTAssertEqual(found?.stationID, 789)
        XCTAssertEqual(found?.stationName, "Persisted")
    }
}
