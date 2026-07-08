public enum DataSource: Equatable, Sendable { case service, direct }

public actor FailoverProvider: WindDataProvider {
    public private(set) var activeSource: DataSource = .service
    private let service: WindDataProvider & HealthCheckable
    private let direct: WindDataProvider

    public init(service: WindDataProvider & HealthCheckable, direct: WindDataProvider) {
        self.service = service; self.direct = direct
    }

    public func fetch(lat: Double, lon: Double) async throws -> Conditions {
        if activeSource == .direct, await service.isHealthy() {
            activeSource = .service
        }

        if activeSource == .service {
            do {
                return try await service.fetch(lat: lat, lon: lon)
            } catch ProviderError.unauthorized {
                throw ProviderError.unauthorized
            } catch {
                activeSource = .direct
            }
        }
        return try await direct.fetch(lat: lat, lon: lon)
    }
}
