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
    var settings = Settings.load(defaults: .standard, secrets: KeychainStore())

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private let locationManager = CLLocationManager()
    private var policy: AlertPolicy?
    private var provider: FailoverProvider?
    private var refreshTask: Task<Void, Never>?
    private let presenter = AlertPresenter()
    private var isStarting = false

    func startSession() async {
        guard phase == .idle, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        let secrets = KeychainStore()
        guard let url = settings.serviceURL, let token = secrets.get(Settings.serviceTokenKey) else {
            lastError = "Configure service URL and token in Settings"
            return
        }
        let service = ServiceClient(baseURL: url, token: token)
        let direct = DirectWindguruClient(username: secrets.get(Settings.wgUsernameKey) ?? "",
                                          microPassword: secrets.get(Settings.wgMicroPasswordKey) ?? "")
        provider = FailoverProvider(service: service, direct: direct)
        policy = AlertPolicy(thresholdKn: settings.thresholdKn)

        locationManager.requestWhenInUseAuthorization()
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.startUpdatingLocation()

        // Workout session failure aborts the session because it's what guarantees background runtime for alerts;
        // the error stays visible on the start screen (the refresh loop, which clears lastError, never starts).
        guard await startWorkout() else {
            locationManager.stopUpdatingLocation()
            provider = nil
            policy = nil
            return
        }
        WKInterfaceDevice.current().enableWaterLock()
        phase = .running
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
    }

    func acknowledgeAlert() {
        presenter.stop()
        if case .alerting = phase { phase = .running }
    }

    private func startWorkout() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "Health data unavailable"
            return false
        }
        do {
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType()], read: [])
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
        do {
            let c = try await provider.fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
            conditions = c
            activeSource = await provider.activeSource
            lastError = nil
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
}
