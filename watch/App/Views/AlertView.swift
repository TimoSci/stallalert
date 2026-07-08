import SwiftUI
import StallAlertKit

struct AlertView: View {
    @Environment(SessionController.self) private var session
    let cause: AlertPolicy.Cause

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wind").font(.largeTitle)
            Text("WIND DROPPING").font(.headline)
            if let nh = session.nextHour {
                Text("\(Int(nh.projectedBaseKn.rounded())) kn \(cause == .predicted ? "forecast" : "measured now")")
                    .font(.title3)
            }
            Button("OK") { session.acknowledgeAlert() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.red.opacity(0.85))
    }
}
