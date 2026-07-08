import SwiftUI
import StallAlertKit

struct StartView: View {
    @Environment(SessionController.self) private var session
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 8) {
            if let nh = session.nextHour {
                Text("\(Int(nh.minKn.rounded()))–\(Int(nh.maxKn.rounded())) kn \(trendSymbol(nh.trend))")
                    .font(.title3)
            } else {
                Text("StallAlert").font(.title3)
            }
            Text("Alert below \(Int(session.settings.thresholdKn)) kn")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Start Session") {
                Task { await session.startSession() }
            }
            .buttonStyle(.borderedProminent).tint(.green)
            if let err = session.lastError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
            Button("Settings") { showSettings = true }.font(.footnote)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task { await session.refreshTick() }
    }
}

func trendSymbol(_ t: Trend) -> String {
    switch t { case .rising: "↑"; case .steady: "→"; case .dropping: "↓" }
}
