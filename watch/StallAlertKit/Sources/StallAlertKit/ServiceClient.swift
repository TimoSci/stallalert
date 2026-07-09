import Foundation

public final class ServiceClient: WindDataProvider, HealthCheckable {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func fetch(lat: Double, lon: Double, stationID: Int?) async throws -> Conditions {
        var comps = URLComponents(url: baseURL.appending(path: "/v1/conditions"), resolvingAgainstBaseURL: false)!
        var queryItems = [URLQueryItem(name: "lat", value: String(lat)), URLQueryItem(name: "lon", value: String(lon))]
        if let stationID {
            queryItems.append(URLQueryItem(name: "station_id", value: String(stationID)))
        }
        comps.queryItems = queryItems
        var req = URLRequest(url: comps.url!, timeoutInterval: 5)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw ProviderError.transport }

        guard let http = resp as? HTTPURLResponse else {
            throw ProviderError.transport
        }

        switch http.statusCode {
        case 200:
            guard let c = try? Conditions.decoder().decode(Conditions.self, from: data) else {
                throw ProviderError.badPayload
            }
            return c
        case 401: throw ProviderError.unauthorized
        case let s where s >= 500: throw ProviderError.serverError(s)
        case let s: throw ProviderError.serverError(s)
        }
    }

    public func isHealthy() async -> Bool {
        var req = URLRequest(url: baseURL.appending(path: "/v1/health"), timeoutInterval: 5)
        req.httpMethod = "GET"
        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}
