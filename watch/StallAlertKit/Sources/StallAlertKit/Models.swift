import Foundation

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
    public init(time: Date, windKn: Double, gustKn: Double, dirDeg: Double) {
        self.time = time
        self.windKn = windKn
        self.gustKn = gustKn
        self.dirDeg = dirDeg
    }
}

public struct Station: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let distanceKm: Double
    public let reading: StationReading?
    public init(id: Int, name: String, distanceKm: Double, reading: StationReading?) {
        self.id = id
        self.name = name
        self.distanceKm = distanceKm
        self.reading = reading
    }
}

public struct Conditions: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let stale: Bool
    public let forecast: Forecast
    public let station: Station?
    public init(generatedAt: Date, stale: Bool, forecast: Forecast, station: Station?) {
        self.generatedAt = generatedAt
        self.stale = stale
        self.forecast = forecast
        self.station = station
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
