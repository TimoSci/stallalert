import SwiftUI
import StallAlertKit
import os

/// Temporary diagnostic for the frozen-main-thread hang on Start Session:
/// stamps wall-clock offsets from process start at each boundary of the
/// launch and session-start paths. Read via Xcode's console while running
/// on the watch. Remove once the stall is attributed and fixed.
enum StartupTrace {
    static let t0 = Date()
    private static let log = Logger(subsystem: "net.timosci.StallAlert", category: "startup")
    static func mark(_ label: String) {
        let dt = Date().timeIntervalSince(t0)
        log.info("[trace +\(dt, format: .fixed(precision: 3), privacy: .public)s] \(label, privacy: .public)")
    }
}

@main
struct StallAlertApp: App {
    @State private var session: SessionController

    init() {
        StartupTrace.mark("app init")
        // Must run before SessionController loads Settings, so a freshly
        // seeded service URL is visible on the very first launch.
        CredentialSeeder.seedFromLaunchEnvironmentIfPresent()
        StartupTrace.mark("seeder done")
        _session = State(initialValue: SessionController())
        StartupTrace.mark("controller ready (Settings.load incl. keychain)")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
    }
}

struct RootView: View {
    @Environment(SessionController.self) private var session

    var body: some View {
        switch session.phase {
        case .idle: StartView()
        case .running: SessionView()
        case .alerting(let cause): AlertView(cause: cause)
        }
    }
}
