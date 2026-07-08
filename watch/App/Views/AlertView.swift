import SwiftUI
import StallAlertKit

struct AlertView: View {
    @Environment(SessionController.self) private var session
    let cause: AlertPolicy.Cause

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wind").font(.largeTitle)
            Text("WIND DROPPING").font(.headline)
            Text(detailText).font(.title3)
            Button("OK") { session.acknowledgeAlert() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.red.opacity(0.85))
    }

    /// `.measured` alerts are caused by the live station reading, not the forecast,
    /// so they must show the live reading — `nextHour.projectedBaseKn` is a forecast
    /// figure and was previously (incorrectly) reused for both causes.
    private var detailText: String {
        switch cause {
        case .measured:
            if let liveKn = session.conditions?.station?.reading?.windKn {
                return "\(Int(liveKn.rounded())) kn measured now"
            }
            return "Wind below threshold"
        case .predicted:
            if let nh = session.nextHour {
                return "\(Int(nh.projectedBaseKn.rounded())) kn forecast"
            }
            return "Wind below threshold"
        }
    }
}
