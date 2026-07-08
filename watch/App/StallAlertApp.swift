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
