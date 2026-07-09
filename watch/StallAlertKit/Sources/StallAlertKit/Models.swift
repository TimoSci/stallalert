import Foundation

public struct NearbyStation: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let distanceKm: Double
    public init(id: Int, name: String, distanceKm: Double) {
        self.id = id
        self.name = name
        self.distanceKm = distanceKm
    }
}

public struct DirectionSample: Codable, Equatable, Sendable {
    public let time: Date
    public let dirDeg: Double
    public init(time: Date, dirDeg: Double) {
        self.time = time
        self.dirDeg = dirDeg
    }
}

public struct WindStep: Codable, Equatable, Sendable {
    public let time: Date
    public let windKn: Double
    public let gustKn: Double
    public let dirDeg: Double
    public init(time: Date, windKn: Double, gustKn: Double, dirDeg: Double) {
        self.time = time
        self.windKn = windKn
        self.gustKn = gustKn
        self.dirDeg = dirDeg
    }
}

public struct Forecast: Codable, Equatable, Sendable {
    public let model: String
    public let initTime: Date
    public let hours: [WindStep]
    public init(model: String, initTime: Date, hours: [WindStep]) {
        self.model = model
        self.initTime = initTime
        self.hours = hours
    }
}

public struct StationReading: Codable, Equatable, Sendable {
    public let time: Date
    public let windKn: Double
    public let gustKn: Double
    public let dirDeg: Double
    public let directionHistory: [DirectionSample]?
    public init(time: Date, windKn: Double, gustKn: Double, dirDeg: Double, directionHistory: [DirectionSample]? = nil) {
        self.time = time
        self.windKn = windKn
        self.gustKn = gustKn
        self.dirDeg = dirDeg
        self.directionHistory = directionHistory
    }
}

public struct Station: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let distanceKm: Double
    public let reading: StationReading?
    public let source: String?
    public init(id: Int, name: String, distanceKm: Double, reading: StationReading?, source: String? = nil) {
        self.id = id
        self.name = name
        self.distanceKm = distanceKm
        self.reading = reading
        self.source = source
    }
}

public struct Conditions: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let stale: Bool
    public let forecast: Forecast
    public let station: Station?
    public let nearbyStations: [NearbyStation]?
    public init(generatedAt: Date, stale: Bool, forecast: Forecast, station: Station?, nearbyStations: [NearbyStation]? = nil) {
        self.generatedAt = generatedAt
        self.stale = stale
        self.forecast = forecast
        self.station = station
        self.nearbyStations = nearbyStations
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
