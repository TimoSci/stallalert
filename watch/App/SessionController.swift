import Foundation
import HealthKit
import CoreLocation
import WatchKit
import StallAlertKit

@Observable
@MainActor
final class SessionController: NSObject {
    enum Phase: Equatable {
        case idle, running
        case alerting(AlertPolicy.Cause)
    }

    private(set) var phase: Phase = .idle
    private(set) var conditions: Conditions?
    private(set) var nextHour: NextHourView?
    private(set) var activeSource: DataSource = .service
    private(set) var lastError: String?
    private(set) var nearbyStations: [NearbyStation] = []
    private(set) var manualStationActive = false
    private(set) var availableModels: [AvailableModel] = []
    private(set) var servedModelCaption: String?
    /// Wall-clock time of the last SUCCESSFUL fetch (any data source), for the
    /// freshness line's green "update" chevron. Distinct from the reading's own
    /// timestamp: a fetch can succeed while the station still serves an old
    /// sample — the gap between the two chevrons is exactly that difference.
    var lastSuccessfulFetch: Date?
    var settings = Settings.load(defaults: .standard, secrets: KeychainStore())

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private let locationManager = CLLocationManager()
    private var policy: AlertPolicy?
    private var provider: FailoverProvider?
    private var refreshTask: Task<Void, Never>?
    private let presenter = AlertPresenter()
    // Observable so StartView can show a spinner during the HealthKit
    // workout spin-up (several seconds on a cold launch), which otherwise
    // gives no visual feedback at all between the tap and phase flipping.
    private(set) var isStarting = false
    private let overrideStore = StationOverrideStore()

    func startSession() async {
        StartupTrace.mark("startSession entry")
        guard phase == .idle, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        // Keychain reads measured at 1.1–1.7 s EACH on-device with a cold
        // daemon (startup trace, 2026-07-15) — off the main actor, so the
        // UI shows the starting state instead of freezing. The detached
        // task builds its own KeychainStore; only Sendable strings cross.
        let (token, username, microPassword) = await Task.detached(priority: .userInitiated) {
            let secrets = KeychainStore()
            return (secrets.get(Settings.serviceTokenKey),
                    secrets.get(Settings.wgUsernameKey),
                    secrets.get(Settings.wgMicroPasswordKey))
        }.value
        StartupTrace.mark("keychain reads done (off-main)")
        guard let url = settings.serviceURL, let token else {
            lastError = "Configure service URL and token in Settings"
            return
        }
        let service = ServiceClient(baseURL: url, token: token)
        let direct = DirectWindguruClient(username: username ?? "",
                                          microPassword: microPassword ?? "")
        provider = FailoverProvider(service: service, direct: direct)
        policy = AlertPolicy(thresholdKn: settings.thresholdKn)
        StartupTrace.mark("providers built")

        locationManager.requestWhenInUseAuthorization()
        StartupTrace.mark("CL requestWhenInUseAuthorization returned")
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.startUpdatingLocation()
        StartupTrace.mark("CL startUpdatingLocation returned")

        // Workout session failure aborts the session because it's what guarantees background runtime for alerts;
        // the error stays visible on the start screen (the refresh loop, which clears lastError, never starts).
        guard await startWorkout() else {
            locationManager.stopUpdatingLocation()
            provider = nil
            policy = nil
            return
        }
        StartupTrace.mark("startWorkout returned")
        WKInterfaceDevice.current().enableWaterLock()
        phase = .running
        StartupTrace.mark("phase = .running")
        startRefreshLoop()
    }

    func endSession() {
        refreshTask?.cancel()
        workoutSession?.end()
        locationManager.stopUpdatingLocation()
        phase = .idle
        // Clear provider/policy so a straggling refreshTick (or StartView's
        // `.task { refreshTick() }`) guard-returns instead of firing a phantom
        // alert from state left over by the ended session.
        provider = nil
        policy = nil
        lastSuccessfulFetch = nil
    }

    func acknowledgeAlert() {
        presenter.stop()
        if case .alerting = phase { phase = .running }
    }

    private func startWorkout() async -> Bool {
        StartupTrace.mark("startWorkout entry")
        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "Health data unavailable"
            return false
        }
        StartupTrace.mark("isHealthDataAvailable done")
        do {
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType()], read: [])
            StartupTrace.mark("HK requestAuthorization done")
        } catch {
            lastError = "Health authorization failed: \(error.localizedDescription)"
            return false
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .surfingSports   // closest type to kitesurfing
        config.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            session.startActivity(with: Date())
            workoutSession = session
            return true
        } catch {
            lastError = "Workout session failed: \(error.localizedDescription)"
            return false
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTick()
                // No data yet (first fetch still pending, e.g. waiting on a GPS fix) —
                // retry quickly instead of waiting the full cadence so the rider gets
                // their first reading fast. Once we have data, fall back to the normal
                // 5-minute cadence.
                let hasData = self?.conditions != nil
                try? await Task.sleep(for: .seconds(hasData ? 5 * 60 : 10))
            }
        }
    }

    func refreshTick() async {
        guard let provider else { return }
        guard let loc = locationManager.location else { return }
        let override = overrideStore.override(nearLat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        let requestedModel = settings.forecastModel == "wg" ? nil : settings.forecastModel
        do {
            let c = try await provider.fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, stationID: override?.stationID, model: requestedModel)
            conditions = c
            lastSuccessfulFetch = Date()
            activeSource = await provider.activeSource
            lastError = nil
            nearbyStations = c.nearbyStations ?? []
            manualStationActive = (override != nil) && (c.station?.source == "manual")
            availableModels = c.availableModels ?? []
            servedModelCaption = Self.servedModelCaption(requested: settings.forecastModel, served: c.forecast.model, availableModels: availableModels)
            evaluateAndMaybeFire()
        } catch ProviderError.unauthorized {
            switch await provider.activeSource {
            case .service: lastError = "Check service token"
            case .direct: lastError = "Check Windguru login"
            }
            evaluateAndMaybeFire()
        } catch ProviderError.notConfigured {
            lastError = "Set Windguru login in Settings"
            evaluateAndMaybeFire()
        } catch {
            lastError = "No data connection"
            evaluateAndMaybeFire()
        }
    }

    /// Pins the given station as the override for the rider's current spot and
    /// refreshes immediately so the picker's selection is reflected right away.
    /// No-ops without a GPS fix, since the override is keyed on location.
    func selectStation(_ station: NearbyStation) {
        guard let loc = locationManager.location else { return }
        overrideStore.set(StationOverride(
            lat: loc.coordinate.latitude,
            lon: loc.coordinate.longitude,
            stationID: station.id,
            stationName: station.name
        ))
        Task { await refreshTick() }
    }

    /// Clears any override for the rider's current spot, reverting to the
    /// nearest-station auto-selection, and refreshes immediately.
    /// No-ops without a GPS fix, since the override lookup is keyed on location.
    func selectAutoStation() {
        guard let loc = locationManager.location else { return }
        overrideStore.clearNear(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        Task { await refreshTick() }
    }

    /// Evaluates the alert policy against whatever conditions are currently cached
    /// (freshly fetched, or stale from a previous tick when this fetch failed) and
    /// fires an alert if warranted. This is what keeps predicted-drop alerts working
    /// while offline: `ForecastEngine.nextHour` slides its window over the cached
    /// timeline and goes nil once the cache ages out of range, and the policy's
    /// live-reading staleness cutoff excludes cached readings older than 20 minutes.
    private func evaluateAndMaybeFire() {
        guard let c = conditions, var policy else { return }
        nextHour = ForecastEngine.nextHour(from: c.forecast, at: Date())

        let reading = c.station?.reading
        let cause = policy.evaluate(.init(
            forecastMinKn: nextHour?.minKn,
            liveKn: reading?.windKn,
            liveAgeSeconds: reading.map { Date().timeIntervalSince($0.time) }
        ))
        self.policy = policy
        // Only fire from an active session — guards against a straggling tick
        // (or the start screen's own refresh) transitioning phase after the
        // session has already ended or before it has started.
        if let cause, phase == .running {
            phase = .alerting(cause)
            presenter.fire()
        }
    }

    /// Rule: nil (no caption) when the served forecast matches what was requested —
    /// "wg" requested + served name starts with "WG blend", or a specific model id
    /// requested + served name equals that id's display name from `availableModels`.
    /// Otherwise the caption is the raw served model string.
    ///
    /// Important: right after switching models, the async server may still serve the
    /// PREVIOUS model's last-good forecast for a tick or two while the new one is
    /// fetched (`requestedModel` echoes the new request but `forecast.model` lags
    /// behind it). Showing that old served name here during the gap is CORRECT — the
    /// caption reflects what's actually on screen, not what was asked for. Do not add
    /// suppression/debounce logic to hide this window.
    private static func servedModelCaption(requested: String, served: String, availableModels: [AvailableModel]) -> String? {
        if requested == "wg" {
            return served.hasPrefix("WG blend") ? nil : served
        }
        let requestedName = availableModels.first(where: { $0.id == requested })?.name
        return served == requestedName ? nil : served
    }
}
