public protocol WindDataProvider: Sendable {
    func fetch(lat: Double, lon: Double, stationID: Int?, model: String?) async throws -> Conditions
}

public extension WindDataProvider {
    func fetch(lat: Double, lon: Double) async throws -> Conditions {
        try await fetch(lat: lat, lon: lon, stationID: nil, model: nil)
    }

    func fetch(lat: Double, lon: Double, stationID: Int?) async throws -> Conditions {
        try await fetch(lat: lat, lon: lon, stationID: stationID, model: nil)
    }
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
