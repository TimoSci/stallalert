import XCTest
@testable import StallAlertKit

/// Thread-safe request counter, keyed by a caller-chosen label (mirrors the
/// pattern StubURLProtocol itself uses for its `nonisolated(unsafe)` handler).
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func increment(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        counts[key, default: 0] += 1
    }

    func count(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[key] ?? 0
    }
}

final class DirectWindguruClientTests: XCTestCase {
    private func fixtureData(_ name: String, ext: String) -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/windguru/\(name)", withExtension: ext)!
        return try! Data(contentsOf: url)
    }

    private func client(username: String = "user", password: String = "pass") -> DirectWindguruClient {
        DirectWindguruClient(username: username, microPassword: password, session: StubURLProtocol.makeSession())
    }

    /// Routes a stub request to the right fixture by host + `q` query param,
    /// mirroring the three real endpoints the client talks to.
    private func defaultHandler(counter: RequestCounter? = nil,
                                 microStatus: Int = 200,
                                 stationListOverride: Data? = nil,
                                 stationDataOverride: Data? = nil) -> (URLRequest) -> (Int, Data) {
        { req in
            let url = req.url!
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let q = query.first { $0.name == "q" }?.value

            switch (url.host, q) {
            case ("micro.windguru.cz", _):
                counter?.increment("micro")
                return (microStatus, self.fixtureData("micro_forecast", ext: "txt"))
            case ("www.windguru.net", "station_list"):
                counter?.increment("stationList")
                return (200, stationListOverride ?? self.fixtureData("stations_list", ext: "json"))
            case ("www.windguru.cz", "station_data"):
                counter?.increment("stationData")
                return (200, stationDataOverride ?? self.fixtureData("station_current", ext: "json"))
            default:
                XCTFail("unexpected request to \(url)")
                return (404, Data())
            }
        }
    }

    // MARK: - 1. Happy path

    func testHappyPathFetch() async throws {
        StubURLProtocol.handler = defaultHandler()

        let conditions = try await client().fetch(lat: 39.92, lon: 3.09)

        XCTAssertEqual(conditions.forecast.model, "gfs-micro")
        XCTAssertEqual(conditions.forecast.hours.count, 179)

        // Nearest entry to (39.92, 3.09) in stations_list.json, verified independently
        // (haversine over the raw fixture): id_station 4048 "KiteandYoga Mallorca",
        // lat 39.858276 / lon 3.101116, ~6.93 km away.
        let station = try XCTUnwrap(conditions.station)
        XCTAssertEqual(station.id, 4048)
        XCTAssertEqual(station.name, "KiteandYoga Mallorca")
        XCTAssertEqual(station.distanceKm, 6.93, accuracy: 0.05)

        // station_current.json's max-unixtime sample (1783398300), re-verified against
        // the file: wind_avg 0.1, wind_max 0.5, wind_direction 148.
        let reading = try XCTUnwrap(station.reading)
        XCTAssertEqual(reading.time, ISO8601DateFormatter().date(from: "2026-07-07T04:25:00Z"))
        XCTAssertEqual(reading.windKn, 0.1)
        XCTAssertEqual(reading.gustKn, 0.5)
        XCTAssertEqual(reading.dirDeg, 148)
    }

    // MARK: - 2. Credentials + headers

    func testCredentialsAndHeaders() async throws {
        StubURLProtocol.handler = { req in
            let url = req.url!
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let q = query.first { $0.name == "q" }?.value

            switch (url.host, q) {
            case ("micro.windguru.cz", _):
                XCTAssertEqual(query.first { $0.name == "u" }?.value, "wguser")
                XCTAssertEqual(query.first { $0.name == "p" }?.value, "wgpass")
                XCTAssertNil(req.value(forHTTPHeaderField: "Referer"))
                return (200, self.fixtureData("micro_forecast", ext: "txt"))
            case ("www.windguru.net", "station_list"):
                XCTAssertEqual(req.value(forHTTPHeaderField: "Referer"), "https://www.windguru.cz/")
                XCTAssertNotNil(req.value(forHTTPHeaderField: "User-Agent"))
                return (200, self.fixtureData("stations_list", ext: "json"))
            case ("www.windguru.cz", "station_data"):
                XCTAssertEqual(req.value(forHTTPHeaderField: "Referer"), "https://www.windguru.cz/")
                XCTAssertNotNil(req.value(forHTTPHeaderField: "User-Agent"))
                return (200, self.fixtureData("station_current", ext: "json"))
            default:
                XCTFail("unexpected request to \(url)")
                return (404, Data())
            }
        }

        _ = try await client(username: "wguser", password: "wgpass").fetch(lat: 39.92, lon: 3.09)
    }

    // MARK: - 3. notConfigured short-circuits before any HTTP

    func testEmptyCredsThrowsNotConfiguredWithNoRequest() async {
        StubURLProtocol.handler = { req in
            XCTFail("no request should be made when credentials are empty: \(req.url!)")
            return (500, Data())
        }

        do {
            _ = try await client(username: "", password: "").fetch(lat: 1, lon: 1)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? ProviderError, .notConfigured)
        }

        do {
            _ = try await client(username: "user", password: "").fetch(lat: 1, lon: 1)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? ProviderError, .notConfigured)
        }
    }

    // MARK: - 4. Caching

    func testCachingReusesForecastStationListAndStationReading() async throws {
        let counter = RequestCounter()
        StubURLProtocol.handler = defaultHandler(counter: counter)

        let c = client()
        _ = try await c.fetch(lat: 39.92, lon: 3.09)
        _ = try await c.fetch(lat: 39.92, lon: 3.09)

        XCTAssertEqual(counter.count("micro"), 1)
        XCTAssertEqual(counter.count("stationList"), 1)
        XCTAssertEqual(counter.count("stationData"), 1)
    }

    /// A rider drifts on the water between ticks, so the forecast cache hit test
    /// can't require exact lat/lon equality — it uses a 2 km radius instead.
    func testForecastCacheHitsWithinRadiusOfGpsDrift() async throws {
        let counter = RequestCounter()
        StubURLProtocol.handler = defaultHandler(counter: counter)

        let c = client()
        _ = try await c.fetch(lat: 39.92, lon: 3.09)
        // ~0.5 km north of the original request (1 deg lat ~= 111.32 km) — within
        // the 2 km cache radius, so this should reuse the cached forecast.
        _ = try await c.fetch(lat: 39.9245, lon: 3.09)

        XCTAssertEqual(counter.count("micro"), 1)
    }

    func testForecastCacheMissesBeyondRadius() async throws {
        let counter = RequestCounter()
        StubURLProtocol.handler = defaultHandler(counter: counter)

        let c = client()
        _ = try await c.fetch(lat: 39.92, lon: 3.09)
        // ~5 km north of the original request — outside the 2 km cache radius,
        // so this must trigger a second micro fetch.
        _ = try await c.fetch(lat: 39.965, lon: 3.09)

        XCTAssertEqual(counter.count("micro"), 2)
    }

    // MARK: - 5. Error mapping + graceful station degradation

    func testMicroServerErrorMapsToServerError() async {
        StubURLProtocol.handler = defaultHandler(microStatus: 500)

        do {
            _ = try await client().fetch(lat: 39.92, lon: 3.09)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? ProviderError, .serverError(500))
        }
    }

    func testStationListFailureDoesNotFailWholeFetch() async throws {
        let garbage = Data("not json".utf8)
        StubURLProtocol.handler = defaultHandler(stationListOverride: garbage)

        // The station leg fails (badPayload internally), but the overall fetch still
        // succeeds with the forecast intact and station nil — this is the graceful
        // degradation contract documented on DirectWindguruClient.
        let conditions = try await client().fetch(lat: 39.92, lon: 3.09)
        XCTAssertEqual(conditions.forecast.hours.count, 179)
        XCTAssertNil(conditions.station)
    }

    // MARK: - 6. Station farther than 30 km

    func testStationFartherThan30kmYieldsNilStation() async throws {
        let farStation = """
        [
          {"id_station": 1, "name": "Too Far Station", "spotname": "Nowhere",
           "lat": 60.0, "lon": 20.0}
        ]
        """
        StubURLProtocol.handler = defaultHandler(stationListOverride: Data(farStation.utf8))

        let conditions = try await client().fetch(lat: 39.92, lon: 3.09)
        XCTAssertEqual(conditions.forecast.hours.count, 179)
        XCTAssertNil(conditions.station)
    }

    // MARK: - 7. Degradation + fallback behavior

    func testStationListWithNoParseableEntriesDegradesToNilStation() async throws {
        let unparseable = """
        [
          {"foo": "bar"},
          {"baz": 1}
        ]
        """
        StubURLProtocol.handler = defaultHandler(stationListOverride: Data(unparseable.utf8))

        // The station list contains no parseable entries. The parseStationList
        // throws badPayload (no stations found in non-empty input), which is caught
        // in fetchStationOrNil and degraded to nil, but the forecast succeeds.
        let conditions = try await client().fetch(lat: 39.92, lon: 3.09)
        XCTAssertEqual(conditions.forecast.hours.count, 179)
        XCTAssertNil(conditions.station)
    }

    func testStationNameFallsBackToSpotname() async throws {
        let stationWithSpotname = """
        [
          {"id_station": 9999, "name": "", "spotname": "Fallback Spot",
           "lat": 39.93, "lon": 3.10}
        ]
        """
        StubURLProtocol.handler = defaultHandler(stationListOverride: Data(stationWithSpotname.utf8))

        let conditions = try await client().fetch(lat: 39.92, lon: 3.09)
        let station = try XCTUnwrap(conditions.station)
        XCTAssertEqual(station.name, "Fallback Spot")
        XCTAssertEqual(station.id, 9999)
    }

    // MARK: - 8. Station override + nearby candidates (Task 7)

    /// A query point placed exactly on the Barcelona-cluster fixture entry
    /// id_station 1959 ("Gava mar", lat 41.26549 / lon 2.01265). This makes
    /// two *distinct* real fixture ids both plausible station choices from
    /// the same query point (verified independently via haversine over the
    /// raw fixture):
    ///   - id 1959 "Gava mar" at 0.0 km -- the auto-nearest choice.
    ///   - id 868 "BUNKER BEACH CLUB" (lat 41.265259 / lon 1.981637) at
    ///     ~2.59 km -- a genuinely different, in-range (<=50 km) manual
    ///     override choice.
    /// Unlike (39.92, 3.09), which has only one fixture station (4048)
    /// within the 50 km override leash, this point exercises manual-vs-auto
    /// actually diverging.
    private let barcelonaClusterLat = 41.26549
    private let barcelonaClusterLon = 2.01265

    func testOverrideStationIsFetchedAndMarkedManual() async throws {
        StubURLProtocol.handler = defaultHandler()

        let conditions = try await client().fetch(
            lat: barcelonaClusterLat, lon: barcelonaClusterLon, stationID: 868
        )

        let station = try XCTUnwrap(conditions.station)
        XCTAssertEqual(station.id, 868)
        XCTAssertEqual(station.name, "BUNKER BEACH CLUB")
        XCTAssertEqual(station.source, "manual")
        XCTAssertEqual(station.distanceKm, 2.6, accuracy: 0.05)
    }

    func testUnknownOverrideFallsBackToAuto() async throws {
        StubURLProtocol.handler = defaultHandler()

        // 999999999 doesn't exist in the fixture station list at all.
        let conditions = try await client().fetch(lat: 39.92, lon: 3.09, stationID: 999_999_999)

        let station = try XCTUnwrap(conditions.station)
        XCTAssertEqual(station.id, 4048)
        XCTAssertEqual(station.source, "auto")
    }

    func testFarOverrideFallsBackToAuto() async throws {
        StubURLProtocol.handler = defaultHandler()

        // id 2367 "Lomas del Cauquen" (Argentina, lat -41.169515 / lon
        // -71.370423) is a real fixture entry, but ~11,735 km from
        // (39.92, 3.09) -- nowhere near the 50 km override leash.
        let conditions = try await client().fetch(lat: 39.92, lon: 3.09, stationID: 2367)

        let station = try XCTUnwrap(conditions.station)
        XCTAssertEqual(station.id, 4048)
        XCTAssertEqual(station.source, "auto")
    }

    func testNearbyStationsPopulated() async throws {
        StubURLProtocol.handler = defaultHandler()

        let conditions = try await client().fetch(lat: 39.92, lon: 3.09)

        let nearby = try XCTUnwrap(conditions.nearbyStations)
        XCTAssertFalse(nearby.isEmpty)
        XCTAssertLessThanOrEqual(nearby.count, 6)
        XCTAssertEqual(nearby.first?.id, 4048)
        for station in nearby {
            XCTAssertLessThanOrEqual(station.distanceKm, 30)
        }
        XCTAssertEqual(nearby.map(\.distanceKm), nearby.map(\.distanceKm).sorted())
    }

    func testExistingAutoPathNowCarriesSource() async throws {
        StubURLProtocol.handler = defaultHandler()

        let conditions = try await client().fetch(lat: 39.92, lon: 3.09)

        let station = try XCTUnwrap(conditions.station)
        XCTAssertEqual(station.source, "auto")
    }

    // MARK: - 9. Direction history (Task 3)

    func testHappyPathFetchCarriesDirectionHistory() async throws {
        StubURLProtocol.handler = defaultHandler()

        let conditions = try await client().fetch(lat: 39.92, lon: 3.09)

        let reading = try XCTUnwrap(conditions.station?.reading)
        let history = try XCTUnwrap(reading.directionHistory)

        // station_current.json has 12 fully-populated samples (verified against
        // fixture: all have unixtime, wind_avg, wind_max, wind_direction present).
        XCTAssertEqual(history.count, 12)

        // Verify ascending by time: each sample's time <= next sample's time.
        for i in 0..<(history.count - 1) {
            XCTAssertLessThanOrEqual(history[i].time, history[i + 1].time)
        }

        // Last entry's time must match the reading's own time (the max-unixtime
        // sample selected by parseStationReading).
        XCTAssertEqual(history.last?.time, reading.time)

        // Verify times match the fixture: first sample at 1783395000, last at 1783398300.
        let expectedFirstTime = Date(timeIntervalSince1970: 1783395000)
        let expectedLastTime = Date(timeIntervalSince1970: 1783398300)
        XCTAssertEqual(history.first?.time, expectedFirstTime)
        XCTAssertEqual(history.last?.time, expectedLastTime)
    }

    func testDirectionHistoryHandlesNilSamples() async throws {
        // Create a station_data response with a mix of populated and nil samples.
        // The test ensures nil-valued samples are absent from the history.
        let stationDataWithNilSample = """
        {
            "unixtime": [1000000, 1000100, 1000200],
            "wind_avg": [1.0, null, 2.0],
            "wind_max": [1.5, 2.0, 2.5],
            "wind_direction": [100, 110, 120]
        }
        """
        StubURLProtocol.handler = defaultHandler(stationDataOverride: Data(stationDataWithNilSample.utf8))

        let conditions = try await client().fetch(lat: 39.92, lon: 3.09)

        let reading = try XCTUnwrap(conditions.station?.reading)
        let history = try XCTUnwrap(reading.directionHistory)

        // Only 2 samples are fully populated (indices 0 and 2); index 1 has a nil
        // wind_avg, so it should be filtered out.
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].time, Date(timeIntervalSince1970: 1000000))
        XCTAssertEqual(history[0].dirDeg, 100)
        XCTAssertEqual(history[1].time, Date(timeIntervalSince1970: 1000200))
        XCTAssertEqual(history[1].dirDeg, 120)

        // The reading itself should be the max-unixtime sample: 1000200, direction 120.
        XCTAssertEqual(reading.time, Date(timeIntervalSince1970: 1000200))
        XCTAssertEqual(reading.dirDeg, 120)
        XCTAssertEqual(reading.windKn, 2.0)
    }
}
