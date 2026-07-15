import SwiftUI
import StallAlertKit

@main
struct StallAlertApp: App {
    @State private var session: SessionController

    init() {
        // Must run before SessionController loads Settings, so a freshly
        // seeded service URL is visible on the very first launch.
        CredentialSeeder.seedFromLaunchEnvironmentIfPresent()
        _session = State(initialValue: SessionController())

        // Warm the slow daemons off-main at launch so the session-start
        // path hits them warm. Measured cold costs (startup traces,
        // 2026-07-15): 1.1–1.7 s PER keychain read, ~3 s for
        // URLSession.shared's first touch. The idle seconds on the start
        // screen absorb this instead of the tap.
        Task.detached(priority: .utility) {
            _ = KeychainStore().get(Settings.serviceTokenKey)
            _ = URLSession.shared.configuration
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
