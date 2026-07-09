import XCTest
@testable import StallAlertKit

final class StationOverrideStoreTests: XCTestCase {
    // MARK: - 1. No override by default

    func testNoOverrideByDefault() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = StationOverrideStore(defaults: defaults)
        let override = store.override(nearLat: 39.92, lon: 3.09)
        XCTAssertNil(override)
    }

    // MARK: - 2. Set and lookup within 5 km

    func testSetAndLookupWithin5km() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
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
        defaults.removePersistentDomain(forName: #function)
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
        defaults.removePersistentDomain(forName: #function)
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
        defaults.removePersistentDomain(forName: #function)
        let store = StationOverrideStore(defaults: defaults)

        // Mallorca location
        let mallorca = StationOverride(lat: 39.858276, lon: 3.101116, stationID: 1000, stationName: "Mallorca")
        store.set(mallorca)

        // Ijburg location (far enough to not replace Mallorca)
        let ijburg = StationOverride(lat: 52.36, lon: 5.04, stationID: 2000, stationName: "Ijburg")
        store.set(ijburg)

        // Lookup near Mallorca
        let nearMallorca = store.override(nearLat: 39.86, lon: 3.10)
        XCTAssertEqual(nearMallorca?.stationID, 1000)
        XCTAssertEqual(nearMallorca?.stationName, "Mallorca")

        // Lookup near Ijburg
        let nearIjburg = store.override(nearLat: 52.35, lon: 5.05)
        XCTAssertEqual(nearIjburg?.stationID, 2000)
        XCTAssertEqual(nearIjburg?.stationName, "Ijburg")
    }

    // MARK: - 6. Clear near removes only that spot

    func testClearNearRemovesOnlyThatSpot() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = StationOverrideStore(defaults: defaults)

        let mallorca = StationOverride(lat: 39.858276, lon: 3.101116, stationID: 1000, stationName: "Mallorca")
        store.set(mallorca)

        let ijburg = StationOverride(lat: 52.36, lon: 5.04, stationID: 2000, stationName: "Ijburg")
        store.set(ijburg)

        // Clear near Mallorca
        store.clearNear(lat: 39.858276, lon: 3.101116)

        // Mallorca should be gone
        let nearMallorca = store.override(nearLat: 39.86, lon: 3.10)
        XCTAssertNil(nearMallorca)

        // Ijburg should still be there
        let nearIjburg = store.override(nearLat: 52.35, lon: 5.05)
        XCTAssertEqual(nearIjburg?.stationID, 2000)
        XCTAssertEqual(nearIjburg?.stationName, "Ijburg")
    }

    // MARK: - 7. Persistence across instances

    func testPersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store1 = StationOverrideStore(defaults: defaults)

        let entry = StationOverride(lat: 39.92, lon: 3.09, stationID: 789, stationName: "Persisted")
        store1.set(entry)

        // Create a new store instance with the same defaults
        let store2 = StationOverrideStore(defaults: defaults)
        let found = store2.override(nearLat: 39.92, lon: 3.09)

        XCTAssertEqual(found?.stationID, 789)
        XCTAssertEqual(found?.stationName, "Persisted")
    }

    // MARK: - 8. Nearest of overlapping spots wins

    func testNearestOfOverlappingSpotsWins() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = StationOverrideStore(defaults: defaults)

        // Entry A at (0.0, 0.0) station 100
        let entryA = StationOverride(lat: 0.0, lon: 0.0, stationID: 100, stationName: "Station A")
        store.set(entryA)

        // Entry B at (0.063, 0.0) station 200, ~7.0 km north (outside 5 km radius of A)
        let entryB = StationOverride(lat: 0.063, lon: 0.0, stationID: 200, stationName: "Station B")
        store.set(entryB)

        // Query 1: (0.027, 0.0) - ~3.0 km from A, ~4.0 km from B - both within 5 km
        // Should return station 100 (nearer)
        let query1 = store.override(nearLat: 0.027, lon: 0.0)
        XCTAssertEqual(query1?.stationID, 100, "At (0.027, 0.0), station 100 should be nearer")

        // Query 2: (0.036, 0.0) - ~4.0 km from A, ~3.0 km from B - both within 5 km
        // Should return station 200 (nearer)
        let query2 = store.override(nearLat: 0.036, lon: 0.0)
        XCTAssertEqual(query2?.stationID, 200, "At (0.036, 0.0), station 200 should be nearer")
    }
}
