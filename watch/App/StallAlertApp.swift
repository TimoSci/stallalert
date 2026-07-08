import SwiftUI
import StallAlertKit

@main
struct StallAlertApp: App {
    @State private var session = SessionController()

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
