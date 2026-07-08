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
}
