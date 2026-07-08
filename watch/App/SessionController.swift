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

        await startWorkout()
        WKInterfaceDevice.current().enableWaterLock()
        phase = .running
        startRefreshLoop()
    }

    func endSession() {
        refreshTask?.cancel()
        workoutSession?.end()
        locationManager.stopUpdatingLocation()
        phase = .idle
    }

    func acknowledgeAlert() {
        presenter.stop()
        if case .alerting = phase { phase = .running }
    }

    private func startWorkout() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "Health data unavailable"
            return
        }
        do {
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType()], read: [])
        } catch {
            lastError = "Health authorization failed: \(error.localizedDescription)"
            return
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .surfingSports   // closest type to kitesurfing
        config.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            session.startActivity(with: Date())
            workoutSession = session
        } catch {
            lastError = "Workout session failed: \(error.localizedDescription)"
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTick()
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
    }

    func refreshTick() async {
        guard let provider, var policy else { return }
        guard let loc = locationManager.location else { return }
        do {
            let c = try await provider.fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
            conditions = c
            nextHour = ForecastEngine.nextHour(from: c.forecast, at: Date())
            activeSource = await provider.activeSource
            lastError = nil

            let reading = c.station?.reading
            let cause = policy.evaluate(.init(
                forecastMinKn: nextHour?.minKn,
                liveKn: reading?.windKn,
                liveAgeSeconds: reading.map { Date().timeIntervalSince($0.time) }
            ))
            self.policy = policy
            if let cause {
                phase = .alerting(cause)
                presenter.fire()
            }
        } catch ProviderError.unauthorized {
            lastError = "Check service token"
        } catch {
            lastError = "No data connection"
        }
    }
}
