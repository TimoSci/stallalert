import Foundation

/// A station override stored in the preferences.
public struct StationOverride: Codable, Equatable, Sendable {
    public let lat: Double
    public let lon: Double
    public let stationID: Int
    public let stationName: String

    public init(lat: Double, lon: Double, stationID: Int, stationName: String) {
        self.lat = lat
        self.lon = lon
        self.stationID = stationID
        self.stationName = stationName
    }

    enum CodingKeys: String, CodingKey {
        case lat
        case lon
        case stationID = "station_id"
        case stationName = "station_name"
    }
}

/// Thread-safe store for per-location station overrides.
///
/// Entries are stored in UserDefaults and persist across app launches.
/// The store operates under a 5 km "stickiness radius": operations that take
/// a lat/lon coordinate match the nearest entry within 5 km of that coordinate.
public final class StationOverrideStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let stickinessKm: Double = 5.0
    private static let storageKey = "station_overrides"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Finds the nearest override within 5 km of the given coordinates.
    /// - Parameters:
    ///   - nearLat: Latitude in degrees
    ///   - lon: Longitude in degrees
    /// - Returns: The nearest override, or nil if no override exists within 5 km
    public func override(nearLat: Double, lon: Double) -> StationOverride? {
        lock.lock(); defer { lock.unlock() }

        let entries = loadEntries()
        var best: (entry: StationOverride, distance: Double)?

        for entry in entries {
            let distance = GeoMath.haversineKm(nearLat, lon, entry.lat, entry.lon)
            guard distance <= Self.stickinessKm else { continue }
            if best == nil || distance < best!.distance {
                best = (entry, distance)
            }
        }

        return best?.entry
    }

    /// Sets an override at the given location.
    ///
    /// If an override already exists within 5 km of this location, it is replaced.
    /// Otherwise, the new override is added to the store.
    /// - Parameter entry: The override to set
    public func set(_ entry: StationOverride) {
        lock.lock(); defer { lock.unlock() }

        var entries = loadEntries()

        // Remove any existing entry within 5 km of the new entry's location
        entries.removeAll { existing in
            let distance = GeoMath.haversineKm(entry.lat, entry.lon, existing.lat, existing.lon)
            return distance <= Self.stickinessKm
        }

        entries.append(entry)
        saveEntries(entries)
    }

    /// Clears any override within 5 km of the given coordinates.
    /// - Parameters:
    ///   - lat: Latitude in degrees
    ///   - lon: Longitude in degrees
    public func clearNear(lat: Double, lon: Double) {
        lock.lock(); defer { lock.unlock() }

        var entries = loadEntries()
        entries.removeAll { entry in
            let distance = GeoMath.haversineKm(lat, lon, entry.lat, entry.lon)
            return distance <= Self.stickinessKm
        }

        saveEntries(entries)
    }

    // MARK: - Private persistence helpers

    private func loadEntries() -> [StationOverride] {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return []
        }

        let decoder = JSONDecoder()
        return (try? decoder.decode([StationOverride].self, from: data)) ?? []
    }

    private func saveEntries(_ entries: [StationOverride]) {
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(entries) {
            defaults.set(encoded, forKey: Self.storageKey)
        }
    }
}
