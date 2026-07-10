import SwiftUI
import StallAlertKit

struct SessionView: View {
    @Environment(SessionController.self) private var session
    @State private var showStationPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let nh = session.nextHour {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NEXT HOUR").font(.caption2).foregroundStyle(.secondary)
                        Text("\(Int(nh.minKn.rounded()))–\(Int(nh.maxKn.rounded())) kn \(trendSymbol(nh.trend))")
                            .font(.title2).bold()
                            .foregroundStyle(color(for: nh.minKn))
                        if nh.trend == .dropping {
                            Text("dropping to ~\(Int(nh.projectedBaseKn.rounded()))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let cap = session.servedModelCaption {
                    Text(cap).font(.caption2).foregroundStyle(.secondary)
                }

                if let st = session.conditions?.station, let r = st.reading {
                    Button {
                        showStationPicker = true
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 3) {
                                Text("NOW · \(st.name) \(st.distanceKm, specifier: "%.1f") km")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if session.manualStationActive {
                                    Image(systemName: "pin.fill").font(.caption2)
                                }
                            }
                            HStack(spacing: 8) {
                                Text("\(Int(r.windKn.rounded())) kn  gust \(Int(r.gustKn.rounded()))")
                                    .font(.title3).bold()
                                    .foregroundStyle(ageSeconds(r) > 20 * 60 ? .secondary : color(for: r.windKn))
                                CompassView(reading: r, stale: ageSeconds(r) > 20 * 60)
                            }
                            Text(ageLabel(r)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    // Still a picker entry point: the served station can be nil
                    // (reading failed / none in range) while candidates exist —
                    // exactly when switching stations matters most.
                    Button {
                        showStationPicker = true
                    } label: {
                        Text("No station nearby").font(.footnote).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Text("⚠ alert < \(Int(session.settings.thresholdKn)) kn").font(.footnote)
                    Spacer()
                    if session.activeSource == .direct {
                        Text("direct").font(.caption2).padding(3)
                            .background(.orange.opacity(0.3), in: Capsule())
                    }
                    if session.lastError != nil {
                        Text("offline").font(.caption2).padding(3)
                            .background(.red.opacity(0.3), in: Capsule())
                    }
                }

                Button("End Session") { session.endSession() }.tint(.red)
            }
        }
        .sheet(isPresented: $showStationPicker) { StationPickerView() }
    }

    private func color(for kn: Double) -> Color {
        let t = session.settings.thresholdKn
        if kn < t { return .red }
        if kn < t + 3 { return .orange }
        return .green
    }
    private func ageSeconds(_ r: StationReading) -> TimeInterval { Date().timeIntervalSince(r.time) }
    private func ageLabel(_ r: StationReading) -> String {
        "updated \(Int(ageSeconds(r) / 60)) min ago"
    }
}
