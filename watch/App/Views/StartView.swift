import SwiftUI
import StallAlertKit

struct StartView: View {
    @Environment(SessionController.self) private var session
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 8) {
            if let nh = session.nextHour {
                HStack(spacing: 6) {
                    Text("\(Int(nh.minKn.rounded()))–\(Int(nh.maxKn.rounded())) kn")
                        .font(.title3)
                    TrendlineView(samplesKn: nh.samplesKn,
                                  thresholdKn: session.settings.thresholdKn,
                                  tint: .primary)
                }
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

/// Mini trendline of the next hour's base wind against a faint dashed
/// alert-threshold line. Replaces the old trend arrow, which was
/// confusable with wind direction. `tint` matches the adjacent numbers'
/// color on each screen. Lives here (with the old shared trendSymbol
/// helper's home) so no new app-target file forces an xcodegen run.
struct TrendlineView: View {
    let samplesKn: [Double]
    let thresholdKn: Double
    let tint: Color
    var size: CGSize = CGSize(width: 36, height: 14)

    var body: some View {
        if let r = TrendlineModel.render(samplesKn: samplesKn, thresholdKn: thresholdKn) {
            ZStack {
                Path { p in
                    let y = (1 - r.thresholdY) * size.height
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                .stroke(.red.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                Path { p in
                    let stepX = size.width / CGFloat(r.ys.count - 1)
                    for (i, y) in r.ys.enumerated() {
                        let pt = CGPoint(x: CGFloat(i) * stepX, y: (1 - y) * size.height)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .frame(width: size.width, height: size.height)
        }
    }
}
