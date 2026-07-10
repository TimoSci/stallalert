import Foundation

/// On-water fallback `WindDataProvider`: talks directly to Windguru when the
/// self-hosted server is unreachable.
///
/// Two independent Windguru surfaces are used (see
/// `docs/windguru-api-notes.md`, and the server's
/// `Stallalert.Windguru.HTTPAdapter` for the reference request shapes):
///
///   - **Forecast**: the PRO micro API (`micro.windguru.cz`) — a plain HTML
///     page with a `<pre>` text table, parsed by `MicroForecastParser`. No
///     cookies/special headers, just `u`/`p` (username/micro password) query
///     credentials.
///   - **Live station**: iapi's public station endpoints — `q=station_list`
///     (global list, `www.windguru.net`) and `q=station_data` (windowed
///     samples for one station, `www.windguru.cz`). No cookie, but a
///     browser-like `User-Agent` + `Referer` are required or these 401.
///
/// ## Caching
///
/// All three responses are cached in-memory per instance (protected by a
/// lock, since watchOS call sites may not be actor-isolated):
///
///   - forecast: reused for 15 minutes when the requested point is within 2 km of
///     the cached point (a rider drifts on the water — an exact lat/lon match would
///     almost never hit and the micro API would get hit every tick, well above its
///     intended cadence)
///   - station reading: reused for 5 minutes (keyed by station id)
///   - parsed station list: reused for 6 hours — the raw payload is ~1 MB
///     over LTE, so it must never be refetched on every tick.
///
/// ## Graceful degradation
///
/// The station side of a fetch (list lookup, nearest-station distance
/// filter, or the station's own reading) is independent of the forecast: any
/// failure there (network, bad payload, no station within 30 km) yields
/// `station: nil` in the returned `Conditions` WITHOUT failing the whole
/// fetch. A forecast failure, by contrast, fails the whole fetch — the
/// forecast is the primary signal this provider exists to deliver.
public final class DirectWindguruClient: WindDataProvider, @unchecked Sendable {
    private let username: String
    private let microPassword: String
    private let session: URLSession
    private let lock = NSLock()

    private var forecastCache: (lat: Double, lon: Double, forecast: Forecast, fetchedAt: Date)?
    private var stationListCache: (stations: [StationEntry], fetchedAt: Date)?
    private var stationReadingCache: (stationId: Int, reading: StationReading, fetchedAt: Date)?

    private static let forecastTTL: TimeInterval = 15 * 60
    private static let stationReadingTTL: TimeInterval = 5 * 60
    private static let stationListTTL: TimeInterval = 6 * 60 * 60
    private static let maxStationDistanceKm: Double = 30
    // `nearbyStations` candidate radius: mirrors the server's `Geo` 30 km
    // "representative" bound (see http_adapter.ex `@candidate_radius_km`) --
    // same value as `maxStationDistanceKm` on purpose, kept as a separate
    // name because the two express different concepts (auto-fallback cutoff
    // vs. candidate-list radius) that happen to share a value today.
    private static let candidateRadiusKm: Double = 30
    private static let nearbyStationsLimit = 6
    // A user-supplied `stationID` override is allowed a wider leash than
    // auto-nearest: mirrors http_adapter.ex `@override_max_km`.
    private static let overrideMaxDistanceKm: Double = 50
    private static let forecastCacheRadiusKm: Double = 2

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/124.0 Safari/537.36 StallAlert/1.0"

    private static let microBase = URL(string: "https://micro.windguru.cz/")!
    private static let czBase = URL(string: "https://www.windguru.cz/int/iapi.php")!
    private static let netBase = URL(string: "https://www.windguru.net/int/iapi.php")!

    public init(username: String, microPassword: String, session: URLSession = .shared) {
        self.username = username
        self.microPassword = microPassword
        self.session = session
    }

    /// `model` is accepted (to satisfy `WindDataProvider`) but deliberately
    /// ignored: this on-water fallback always fetches the PRO micro API's
    /// single GFS run (`m=gfs` below). Per the WG-blend spec's no-on-watch-blending
    /// decision, model selection/blending is server-side only — the direct
    /// client has no server to defer to, so it stays on plain micro-GFS
    /// regardless of what the caller requests.
    public func fetch(lat: Double, lon: Double, stationID: Int?, model: String?) async throws -> Conditions {
        guard !username.isEmpty, !microPassword.isEmpty else {
            throw ProviderError.notConfigured
        }

        let forecast = try await fetchForecast(lat: lat, lon: lon)
        let stationLeg = await fetchStationLeg(lat: lat, lon: lon, stationID: stationID)

        return Conditions(
            generatedAt: Date(),
            stale: false,
            forecast: forecast,
            station: stationLeg.station,
            nearbyStations: stationLeg.nearbyStations
        )
    }

    // MARK: - Forecast (micro API)

    private func fetchForecast(lat: Double, lon: Double) async throws -> Forecast {
        if let cached = readForecastCache(lat: lat, lon: lon) {
            return cached
        }

        var comps = URLComponents(url: Self.microBase, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "p", value: microPassword),
            URLQueryItem(name: "m", value: "gfs"),
        ]
        let request = URLRequest(url: comps.url!, timeoutInterval: 5)

        let (data, response) = try await perform(request)
        guard response.statusCode == 200 else {
            throw statusError(response.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8),
              let forecast = MicroForecastParser.parse(html) else {
            throw ProviderError.badPayload
        }

        writeForecastCache(lat: lat, lon: lon, forecast: forecast)
        return forecast
    }

    // MARK: - Station (iapi station_list + station_data)

    private struct StationEntry {
        let id: Int
        let name: String
        let lat: Double
        let lon: Double
    }

    /// The station leg is fully independent of the forecast leg. Two
    /// failure scopes are distinguished, per this client's documented
    /// graceful-degradation contract:
    ///
    ///   - the station **list** fetch fails (transport, bad payload) -- both
    ///     `station` and `nearbyStations` degrade to `nil`, since neither can
    ///     be computed without the list.
    ///   - the list fetch succeeds but the chosen station's own reading
    ///     fetch fails, or no station is in range -- `station` is `nil`, but
    ///     `nearbyStations` is still populated from the list.
    ///
    /// `stationID`, when non-nil and resolvable (see `resolveStation`),
    /// selects that station directly (`source: "manual"`) instead of
    /// falling through to nearest-station lookup (`source: "auto"`).
    private func fetchStationLeg(
        lat: Double, lon: Double, stationID: Int?
    ) async -> (station: Station?, nearbyStations: [NearbyStation]?) {
        guard let stations = try? await fetchStationList() else {
            return (nil, nil)
        }

        let nearby = Self.buildNearbyStations(stations, lat: lat, lon: lon)

        guard let resolved = Self.resolveStation(stations, lat: lat, lon: lon, stationID: stationID) else {
            return (nil, nearby)
        }

        do {
            let reading = try await fetchStationReading(id: resolved.entry.id)
            let station = Station(
                id: resolved.entry.id,
                name: resolved.entry.name,
                distanceKm: Self.roundedKm(resolved.distanceKm),
                reading: reading,
                source: resolved.source
            )
            return (station, nearby)
        } catch {
            return (nil, nearby)
        }
    }

    /// Chooses which station to fetch a reading for, mirroring the server's
    /// `station_by_id`/`nearest_station` split (http_adapter.ex):
    ///
    ///   - `stationID`, if non-nil, found in the list, and within
    ///     `overrideMaxDistanceKm` (compared **unrounded** -- matches the
    ///     server's fixed round-before-compare bug) -> that station,
    ///     `source: "manual"`.
    ///   - otherwise -> nearest station within `maxStationDistanceKm`,
    ///     `source: "auto"` (unknown/out-of-range overrides fall through to
    ///     this same path).
    private static func resolveStation(
        _ stations: [StationEntry], lat: Double, lon: Double, stationID: Int?
    ) -> (entry: StationEntry, distanceKm: Double, source: String)? {
        if let stationID, let entry = stations.first(where: { $0.id == stationID }) {
            let distance = GeoMath.haversineKm(lat, lon, entry.lat, entry.lon)
            if distance <= overrideMaxDistanceKm {
                return (entry, distance, "manual")
            }
        }

        guard let nearest = nearestStation(stations, lat: lat, lon: lon) else {
            return nil
        }
        return (nearest.entry, nearest.distanceKm, "auto")
    }

    /// All stations within `candidateRadiusKm` (compared unrounded), nearest
    /// first, capped at `nearbyStationsLimit` -- mirrors the server's
    /// `stations_near/3`. Distances are rounded to 0.1 in this output only.
    private static func buildNearbyStations(
        _ stations: [StationEntry], lat: Double, lon: Double
    ) -> [NearbyStation] {
        stations
            .map { entry in (entry, GeoMath.haversineKm(lat, lon, entry.lat, entry.lon)) }
            .filter { $0.1 <= candidateRadiusKm }
            .sorted { $0.1 < $1.1 }
            .prefix(nearbyStationsLimit)
            .map { NearbyStation(id: $0.0.id, name: $0.0.name, distanceKm: roundedKm($0.1)) }
    }

    private static func roundedKm(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func fetchStationList() async throws -> [StationEntry] {
        if let cached = readStationListCache() {
            return cached
        }

        var comps = URLComponents(url: Self.netBase, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "q", value: "station_list"),
            URLQueryItem(name: "id_type", value: "0"),
            URLQueryItem(name: "seconds", value: "1800"),
            URLQueryItem(name: "seconds_alive", value: "172800"),
        ]
        var request = URLRequest(url: comps.url!, timeoutInterval: 5)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.windguru.cz/", forHTTPHeaderField: "Referer")

        let (data, response) = try await perform(request)
        guard response.statusCode == 200 else {
            throw statusError(response.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let array = json as? [[String: Any]] else {
            throw ProviderError.badPayload
        }

        let stations = array.compactMap(Self.parseStationEntry)
        // Mirrors station_parser.ex: skip unusable entries rather than failing the
        // whole list, but a non-empty input that yields nothing usable is an error.
        if stations.isEmpty && !array.isEmpty {
            throw ProviderError.badPayload
        }

        writeStationListCache(stations)
        return stations
    }

    private static func parseStationEntry(_ dict: [String: Any]) -> StationEntry? {
        guard let id = dict["id_station"] as? Int,
              let lat = (dict["lat"] as? NSNumber)?.doubleValue,
              let lon = (dict["lon"] as? NSNumber)?.doubleValue else {
            return nil
        }

        let name: String?
        if let n = dict["name"] as? String, !n.isEmpty {
            name = n
        } else if let s = dict["spotname"] as? String, !s.isEmpty {
            name = s
        } else {
            name = nil
        }
        guard let finalName = name else { return nil }

        return StationEntry(id: id, name: finalName, lat: lat, lon: lon)
    }

    private static func nearestStation(
        _ stations: [StationEntry], lat: Double, lon: Double
    ) -> (entry: StationEntry, distanceKm: Double)? {
        var best: (entry: StationEntry, distanceKm: Double)?
        for entry in stations {
            let distance = GeoMath.haversineKm(lat, lon, entry.lat, entry.lon)
            guard distance <= maxStationDistanceKm else { continue }
            if best == nil || distance < best!.distanceKm {
                best = (entry, distance)
            }
        }
        return best
    }

    private func fetchStationReading(id: Int) async throws -> StationReading {
        if let cached = readStationReadingCache(id: id) {
            return cached
        }

        let now = Date()
        let from = now.addingTimeInterval(-60 * 60)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var comps = URLComponents(url: Self.czBase, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "q", value: "station_data"),
            URLQueryItem(name: "id_station", value: String(id)),
            URLQueryItem(name: "from", value: iso.string(from: from)),
            URLQueryItem(name: "to", value: iso.string(from: now)),
            URLQueryItem(name: "avg_minutes", value: "5"),
        ]
        var request = URLRequest(url: comps.url!, timeoutInterval: 5)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.windguru.cz/", forHTTPHeaderField: "Referer")

        let (data, response) = try await perform(request)
        guard response.statusCode == 200 else {
            throw statusError(response.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reading = Self.parseStationReading(json) else {
            throw ProviderError.badPayload
        }

        writeStationReadingCache(id: id, reading: reading)
        return reading
    }

    /// Mirrors `Stallalert.Windguru.StationParser.parse_reading/1`: `q=station_data`
    /// returns a time-windowed series (parallel `unixtime`/`wind_avg`/`wind_max`/
    /// `wind_direction` arrays, one element per bucketed sample), not a single
    /// reading. Unequal array lengths are an error. A sample only counts if all
    /// four values are present (non-null) at that index; the reading returned is
    /// the sample with the greatest `unixtime`, not simply the last array index.
    ///
    /// The reading also carries `directionHistory`: every usable sample from the
    /// same window (nil-skipped, per the rule above), ascending by time, with the
    /// last entry being the selected reading's own time/direction.
    private static func parseStationReading(_ json: [String: Any]) -> StationReading? {
        guard let unixtimes = json["unixtime"] as? [Any],
              let avgs = json["wind_avg"] as? [Any],
              let maxs = json["wind_max"] as? [Any],
              let dirs = json["wind_direction"] as? [Any],
              unixtimes.count == avgs.count,
              unixtimes.count == maxs.count,
              unixtimes.count == dirs.count else {
            return nil
        }

        var best: (unixtime: Int, avg: Double, max: Double, dir: Double)?
        var usableSamples: [(unixtime: Int, dir: Double)] = []

        for i in 0..<unixtimes.count {
            guard let t = (unixtimes[i] as? NSNumber)?.intValue,
                  let avg = (avgs[i] as? NSNumber)?.doubleValue,
                  let max = (maxs[i] as? NSNumber)?.doubleValue,
                  let dir = (dirs[i] as? NSNumber)?.doubleValue else {
                continue
            }

            // Collect all usable samples for direction history.
            usableSamples.append((t, dir))

            // Track the max-unixtime sample for the main reading.
            if best == nil || t > best!.unixtime {
                best = (t, avg, max, dir)
            }
        }

        guard let sample = best else { return nil }

        // Build direction history: sort usable samples ascending by time, then
        // map to DirectionSample objects.
        let directionHistory = usableSamples
            .sorted { $0.unixtime < $1.unixtime }
            .map { DirectionSample(time: Date(timeIntervalSince1970: Double($0.unixtime)), dirDeg: $0.dir) }

        return StationReading(
            time: Date(timeIntervalSince1970: Double(sample.unixtime)),
            windKn: sample.avg,
            gustKn: sample.max,
            dirDeg: sample.dir,
            directionHistory: directionHistory
        )
    }

    // MARK: - HTTP plumbing

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.transport
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.transport
        }
        return (data, http)
    }

    private func statusError(_ status: Int) -> ProviderError {
        switch status {
        case 401, 403: return .unauthorized
        default: return .serverError(status)
        }
    }

    // MARK: - Cache access (lock-protected)

    private func readForecastCache(lat: Double, lon: Double) -> Forecast? {
        lock.lock(); defer { lock.unlock() }
        guard let cache = forecastCache,
              Date().timeIntervalSince(cache.fetchedAt) < Self.forecastTTL,
              GeoMath.haversineKm(cache.lat, cache.lon, lat, lon)
                  <= Self.forecastCacheRadiusKm else {
            return nil
        }
        return cache.forecast
    }

    private func writeForecastCache(lat: Double, lon: Double, forecast: Forecast) {
        lock.lock(); defer { lock.unlock() }
        forecastCache = (lat, lon, forecast, Date())
    }

    private func readStationListCache() -> [StationEntry]? {
        lock.lock(); defer { lock.unlock() }
        guard let cache = stationListCache,
              Date().timeIntervalSince(cache.fetchedAt) < Self.stationListTTL else {
            return nil
        }
        return cache.stations
    }

    private func writeStationListCache(_ stations: [StationEntry]) {
        lock.lock(); defer { lock.unlock() }
        stationListCache = (stations, Date())
    }

    private func readStationReadingCache(id: Int) -> StationReading? {
        lock.lock(); defer { lock.unlock() }
        guard let cache = stationReadingCache,
              cache.stationId == id,
              Date().timeIntervalSince(cache.fetchedAt) < Self.stationReadingTTL else {
            return nil
        }
        return cache.reading
    }

    private func writeStationReadingCache(id: Int, reading: StationReading) {
        lock.lock(); defer { lock.unlock() }
        stationReadingCache = (id, reading, Date())
    }
}
