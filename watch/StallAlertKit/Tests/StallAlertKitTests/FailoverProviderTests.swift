import XCTest
@testable import StallAlertKit

private final class FakeService: WindDataProvider, HealthCheckable, @unchecked Sendable {
    var result: Result<Conditions, Error> = .failure(ProviderError.transport)
    var healthy = false
    var fetchCount = 0
    func fetch(lat: Double, lon: Double) async throws -> Conditions {
        fetchCount += 1
        return try result.get()
    }
    func isHealthy() async -> Bool { healthy }
}

private final class FakeDirect: WindDataProvider, @unchecked Sendable {
    var result: Result<Conditions, Error> = .failure(ProviderError.transport)
    var fetchCount = 0
    func fetch(lat: Double, lon: Double) async throws -> Conditions {
        fetchCount += 1
        return try result.get()
    }
}

private func sampleConditions() -> Conditions {
    Conditions(generatedAt: Date(), stale: false,
               forecast: Forecast(model: "wg", initTime: Date(), hours: []), station: nil)
}

final class FailoverProviderTests: XCTestCase {
    func testUsesServiceWhenItWorks() async throws {
        let service = FakeService(); service.result = .success(sampleConditions())
        let direct = FakeDirect()
        let p = FailoverProvider(service: service, direct: direct)
        _ = try await p.fetch(lat: 1, lon: 1)
        let source = await p.activeSource
        XCTAssertEqual(source, .service)
        XCTAssertEqual(direct.fetchCount, 0)
    }

    func testFailsOverOnTransportErrorAndServesViaDirect() async throws {
        let service = FakeService()   // fails with .transport
        let direct = FakeDirect(); direct.result = .success(sampleConditions())
        let p = FailoverProvider(service: service, direct: direct)
        _ = try await p.fetch(lat: 1, lon: 1)
        let source = await p.activeSource
        XCTAssertEqual(source, .direct)
        XCTAssertEqual(direct.fetchCount, 1)
    }

    func testRecoversWhenHealthProbeSucceeds() async throws {
        let service = FakeService()
        let direct = FakeDirect(); direct.result = .success(sampleConditions())
        let p = FailoverProvider(service: service, direct: direct)
        _ = try await p.fetch(lat: 1, lon: 1)                    // fails over
        service.healthy = true; service.result = .success(sampleConditions())
        _ = try await p.fetch(lat: 1, lon: 1)                    // probes, recovers
        let source = await p.activeSource
        XCTAssertEqual(source, .service)
        XCTAssertEqual(service.fetchCount, 2)
    }

    func testStaysDirectWhileServiceUnhealthy() async throws {
        let service = FakeService()
        let direct = FakeDirect(); direct.result = .success(sampleConditions())
        let p = FailoverProvider(service: service, direct: direct)
        _ = try await p.fetch(lat: 1, lon: 1)
        _ = try await p.fetch(lat: 1, lon: 1)
        let source = await p.activeSource
        XCTAssertEqual(source, .direct)
        XCTAssertEqual(service.fetchCount, 1)   // no re-fetch attempts, only cheap health probes
    }

    func testUnauthorizedIsNotFailover() async {
        let service = FakeService(); service.result = .failure(ProviderError.unauthorized)
        let direct = FakeDirect(); direct.result = .success(sampleConditions())
        let p = FailoverProvider(service: service, direct: direct)
        do { _ = try await p.fetch(lat: 1, lon: 1); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? ProviderError, .unauthorized) }
        let source = await p.activeSource
        XCTAssertEqual(source, .service)
        XCTAssertEqual(direct.fetchCount, 0)
    }

    func testBothDownThrows() async {
        let service = FakeService()
        let direct = FakeDirect()
        let p = FailoverProvider(service: service, direct: direct)
        do { _ = try await p.fetch(lat: 1, lon: 1); XCTFail("should throw") }
        catch { XCTAssertTrue(error is ProviderError) }
    }
}
