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

        // Warm the slow daemons off-main at launch so the session-start
        // path hits them warm. Measured cold costs (startup traces,
        // 2026-07-15): 1.1–1.7 s PER keychain read, ~3 s for
        // URLSession.shared's first touch. The idle seconds on the start
        // screen absorb this instead of the tap.
        Task.detached(priority: .utility) {
            _ = KeychainStore().get(Settings.serviceTokenKey)
            _ = URLSession.shared.configuration
            StartupTrace.mark("daemon prewarm done (detached)")
        }

        // TEMP diagnostic (with StartupTrace): heartbeat that logs any
        // main-thread stall beyond ~0.5 s for the first 2 minutes, stamped
        // at the moment the stall ENDS — locates blocks that happen where
        // no trace mark lives (e.g. before a queued tap is delivered).
        Task { @MainActor in
            var last = Date()
            while Date().timeIntervalSince(StartupTrace.t0) < 120 {
                try? await Task.sleep(for: .milliseconds(250))
                let now = Date()
                let gap = now.timeIntervalSince(last)
                if gap > 0.75 {
                    StartupTrace.mark("MAIN-THREAD STALL ~\(String(format: "%.2f", gap - 0.25))s ended")
                }
                last = now
            }
        }
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
