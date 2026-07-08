import Foundation

/// Shared geographic math utilities.
public enum GeoMath {
    /// Computes the great-circle distance between two points on Earth using the haversine formula.
    /// - Parameters:
    ///   - lat1: Latitude of the first point in degrees
    ///   - lon1: Longitude of the first point in degrees
    ///   - lat2: Latitude of the second point in degrees
    ///   - lon2: Longitude of the second point in degrees
    /// - Returns: Distance in kilometers
    public static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let earthRadiusKm = 6371.0
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let deltaPhi = (lat2 - lat1) * .pi / 180
        let deltaLambda = (lon2 - lon1) * .pi / 180
        let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusKm * c
    }
}
