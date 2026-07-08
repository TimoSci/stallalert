public protocol WindDataProvider: Sendable {
    func fetch(lat: Double, lon: Double) async throws -> Conditions
}

public protocol HealthCheckable: Sendable {
    func isHealthy() async -> Bool
}

public enum ProviderError: Error, Equatable {
    case unauthorized
    case serverError(Int)
    case badPayload
    case transport
    case notConfigured
}
