import XCTest
@testable import StallAlertKit

final class ServiceClientTests: XCTestCase {
    private var fixture: Data {
        let url = Bundle.module.url(forResource: "Fixtures/conditions", withExtension: "json")!
        return try! Data(contentsOf: url)
    }
    private func client() -> ServiceClient {
        ServiceClient(baseURL: URL(string: "https://stallalert.example.com")!,
                      token: "tok", session: StubURLProtocol.makeSession())
    }

    func testFetchSendsAuthAndDecodes() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            XCTAssertTrue(req.url!.absoluteString.contains("/v1/conditions?"))
            XCTAssertTrue(req.url!.query!.contains("lat=52.36"))
            XCTAssertFalse(req.url!.query!.contains("station_id"))
            return (200, self.fixture)
        }
        let c = try await client().fetch(lat: 52.36, lon: 5.04)
        XCTAssertEqual(c.station?.name, "Ijburg")
    }

    func testFetchIncludesStationIDWhenSet() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.query!.contains("station_id=4048"))
            return (200, self.fixture)
        }
        let c = try await client().fetch(lat: 52.36, lon: 5.04, stationID: 4048)
        XCTAssertEqual(c.station?.name, "Ijburg")
    }

    func testFetchIncludesModelWhenSet() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.query!.contains("model=52"))
            return (200, self.fixture)
        }
        let c = try await client().fetch(lat: 52.36, lon: 5.04, stationID: nil, model: "52")
        XCTAssertEqual(c.station?.name, "Ijburg")
    }

    func testFetchOmitsModelWhenNil() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertFalse(req.url!.query!.contains("model"))
            return (200, self.fixture)
        }
        let c = try await client().fetch(lat: 52.36, lon: 5.04, stationID: nil, model: nil)
        XCTAssertEqual(c.station?.name, "Ijburg")
    }

    func testFetchOmitsModelWhenWg() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertFalse(req.url!.query!.contains("model"))
            return (200, self.fixture)
        }
        let c = try await client().fetch(lat: 52.36, lon: 5.04, stationID: nil, model: "wg")
        XCTAssertEqual(c.station?.name, "Ijburg")
    }

    func testUnauthorizedMapsToUnauthorized() async {
        StubURLProtocol.handler = { _ in (401, Data()) }
        do { _ = try await client().fetch(lat: 1, lon: 1); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? ProviderError, .unauthorized) }
    }

    func testServerErrorMapsToServerError() async {
        StubURLProtocol.handler = { _ in (503, Data()) }
        do { _ = try await client().fetch(lat: 1, lon: 1); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? ProviderError, .serverError(503)) }
    }

    func testGarbageBodyMapsToBadPayload() async {
        StubURLProtocol.handler = { _ in (200, Data("nope".utf8)) }
        do { _ = try await client().fetch(lat: 1, lon: 1); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? ProviderError, .badPayload) }
    }

    func testHealthCheck() async {
        StubURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.path.hasSuffix("/v1/health"))
            return (200, Data(#"{"status":"ok"}"#.utf8))
        }
        let healthy = await client().isHealthy()
        XCTAssertTrue(healthy)
        StubURLProtocol.handler = { _ in (500, Data()) }
        let unhealthy = await client().isHealthy()
        XCTAssertFalse(unhealthy)
    }
}
