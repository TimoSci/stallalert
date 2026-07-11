import SwiftUI
import WatchKit
import StallAlertKit

struct SessionView: View {
    @Environment(SessionController.self) private var session
    @State private var showStationPicker = false
    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let nh = session.nextHour {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NEXT HOUR").font(.caption2).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text("\(Int(nh.minKn.rounded()))–\(Int(nh.maxKn.rounded())) kn")
                                .font(.title2).bold()
                                .foregroundStyle(color(for: nh.minKn))
                            TrendlineView(samplesKn: nh.samplesKn,
                                          thresholdKn: session.settings.thresholdKn,
                                          tint: color(for: nh.minKn))
                        }
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
                    VStack(alignment: .leading, spacing: 2) {
                        // Row 1: station identity — still the picker entry point.
                        Button {
                            showStationPicker = true
                        } label: {
                            HStack(spacing: 3) {
                                Text("NOW · \(st.name) \(st.distanceKm, specifier: "%.1f") km")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if session.manualStationActive {
                                    Image(systemName: "pin.fill").font(.caption2)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        // Rows 2–3: live numbers + freshness — tap to force a refresh.
                        Button {
                            guard !isRefreshing else { return }
                            WKInterfaceDevice.current().play(.click)
                            isRefreshing = true
                            Task {
                                await session.refreshTick()
                                isRefreshing = false
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text("\(Int(r.windKn.rounded())) kn  gust \(Int(r.gustKn.rounded()))")
                                        .font(.title3).bold()
                                        .foregroundStyle(ageSeconds(r) > 20 * 60 ? .secondary : color(for: r.windKn))
                                    CompassView(reading: r, stale: ageSeconds(r) > 20 * 60)
                                }
                                FreshnessLineView(readingTime: r.time)
                                    .opacity(isRefreshing ? 0.4 : 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
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
}

/// "updated n min ago" plus a thin dotted age track: a `<` marker travels
/// from the `|` origin to the right edge over 15 min, then becomes a clock
/// symbol. Text fades greyish-green -> gray over the first 5 min.
/// Lives inside SessionView.swift deliberately: adding an app-target file
/// would force an xcodegen regeneration (scheme-wipe ritual).
private struct FreshnessLineView: View {
    let readingTime: Date

    var body: some View {
        // 15 s cadence keeps fade/marker/minutes moving between fetches.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let f = FreshnessModel.render(readingTime: readingTime, now: context.date)
            let minutes = Int(max(0, context.date.timeIntervalSince(readingTime)) / 60)
            HStack(spacing: 6) {
                Text("updated \(minutes) min ago")
                    .font(.footnote)
                    .foregroundStyle(textColor(greenness: f.greenness))
                    .fixedSize()
                track(f)
            }
        }
    }

    // Endpoints per spec: clearly green-tinted at 1, ~.secondary gray at 0.
    private func textColor(greenness: Double) -> Color {
        Color(hue: 0.36, saturation: 0.35 * greenness, brightness: 0.75)
    }

    private func track(_ f: FreshnessRender) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.secondary.opacity(0.6))
                    .frame(width: 1.5, height: 10)
                HStack(spacing: 0) {
                    ForEach(0..<12, id: \.self) { _ in
                        Circle()
                            .fill(.secondary.opacity(0.35))
                            .frame(width: 1.5, height: 1.5)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.leading, 3)
                .frame(height: 10)
                if f.showClock {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .position(x: w - 5, y: geo.size.height / 2)
                } else {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .position(x: 4 + (w - 8) * f.markerFraction, y: geo.size.height / 2)
                }
            }
        }
        .frame(height: 12)
    }
}
