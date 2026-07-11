# NEXT HOUR Trendline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the trend arrow next to the NEXT HOUR forecast (confusable with wind direction) with a mini trendline of the next hour's base wind drawn against a faint alert-threshold line, on both screens.

**Architecture:** Spec 2026-07-11-next-hour-trendline-design.md. `ForecastEngine.nextHour` exposes the 7 base-wind samples it already computes (`NextHourView.samplesKn`, appended last with `= []` default); a pure `TrendlineModel` normalizes samples + threshold into [0, 1] y-coordinates; an internal `TrendlineView` in `StartView.swift` (replacing the `trendSymbol` helper, shared by both screens — no new app-target file) draws the line and dashes.

**Tech Stack:** existing — Swift 6 strict-concurrency StallAlertKit package + SwiftUI watch app. No new dependencies. No server changes.

## Global Constraints

- Normalization: `lo = min(samples.min, threshold)`, `hi = max(samples.max, threshold)`; if `hi − lo < 4` expand symmetrically around the midpoint to exactly 4; `y(v) = (v − lo)/(hi − lo)`; `render` returns nil when `samplesKn.count < 2`.
- View: ~36 × 14 pt; sample line stroke 1.5 pt rounded cap/join in the passed `tint`; threshold line horizontal dashed `[2, 2]`, 1 pt, `.red.opacity(0.4)`; normalized y flipped for screen coordinates (1 = top).
- `trendSymbol(_:)` deleted entirely; the `Trend` enum and the "dropping to ~X" caption stay.
- All new init params appended LAST with defaults — existing call sites and committed tests must compile unchanged.
- **NO new app-target files** → NO xcodegen; scheme guard: `grep -c STALLALERT_ watch/StallAlert.xcodeproj/xcshareddata/xcschemes/StallAlert.xcscheme` prints `4` before AND after.
- Watch norms: `cd watch/StallAlertKit && swift test` zero failures, zero warnings; app builds via `xcodebuild -project watch/StallAlert.xcodeproj -scheme StallAlert -destination 'generic/platform=watchOS Simulator' build`.
- Branch: `next-hour-trendline` off `main`.

---

### Task 1: Package — samplesKn + TrendlineModel

**Files:**
- Modify: `watch/StallAlertKit/Sources/StallAlertKit/ForecastEngine.swift`
- Create: `watch/StallAlertKit/Sources/StallAlertKit/TrendlineModel.swift`
- Test: `watch/StallAlertKit/Tests/StallAlertKitTests/TrendlineModelTests.swift` (new), `watch/StallAlertKit/Tests/StallAlertKitTests/ForecastEngineTests.swift` (extend)

**Interfaces:**
- Consumes: `ForecastEngine.nextHour`'s existing `bases` array (7 interpolated 10-min samples).
- Produces (Task 2 relies on these exact names):

```swift
// NextHourView gains, appended LAST:
//   public let samplesKn: [Double]
//   init(..., samplesKn: [Double] = [])
public struct TrendlineRender: Equatable, Sendable {
    public let ys: [Double]       // [0, 1], 0 = range bottom; one per sample
    public let thresholdY: Double // same space
    public init(ys: [Double], thresholdY: Double)
}
public enum TrendlineModel {
    public static func render(samplesKn: [Double], thresholdKn: Double) -> TrendlineRender?
}
```

- [ ] **Step 1: Write the failing tests.** Create `TrendlineModelTests.swift`:

```swift
import XCTest
@testable import StallAlertKit

final class TrendlineModelTests: XCTestCase {
    func testThresholdBelowSamples() {
        let r = TrendlineModel.render(samplesKn: [10, 12], thresholdKn: 8)!
        XCTAssertEqual(r.ys, [0.5, 1.0])
        XCTAssertEqual(r.thresholdY, 0.0)
    }

    func testThresholdAboveSamplesStaysInFrame() {
        let r = TrendlineModel.render(samplesKn: [10, 12], thresholdKn: 15)!
        XCTAssertEqual(r.thresholdY, 1.0)
        XCTAssertEqual(r.ys[0], 0.0)
        XCTAssertEqual(r.ys[1], 0.4, accuracy: 0.0001)
    }

    func testMinimumSpanExpansion() {
        // natural span 1 kn -> expanded to 4 around midpoint 10.5 (8.5...12.5)
        let r = TrendlineModel.render(samplesKn: [10, 11], thresholdKn: 10.5)!
        XCTAssertEqual(r.ys[0], 0.375, accuracy: 0.0001)
        XCTAssertEqual(r.ys[1], 0.625, accuracy: 0.0001)
        XCTAssertEqual(r.thresholdY, 0.5, accuracy: 0.0001)
    }

    func testSamplesSpanningThreshold() {
        let r = TrendlineModel.render(samplesKn: [6, 12], thresholdKn: 9)!
        XCTAssertEqual(r.thresholdY, 0.5, accuracy: 0.0001)
        XCTAssertEqual(r.ys, [0.0, 1.0])
    }

    func testTooFewSamplesReturnsNil() {
        XCTAssertNil(TrendlineModel.render(samplesKn: [], thresholdKn: 10))
        XCTAssertNil(TrendlineModel.render(samplesKn: [10], thresholdKn: 10))
    }
}
```

In `ForecastEngineTests.swift`, extend the existing happy-path test (the one that unwraps a non-nil `nextHour` result from a forecast fixture) with three assertions on its already-unwrapped result value (here called `nh` — match the local name in that test):

```swift
XCTAssertEqual(nh.samplesKn.count, 7)
XCTAssertEqual(nh.samplesKn.last!, nh.projectedBaseKn, accuracy: 0.0001)
XCTAssertEqual(nh.samplesKn.min()!, nh.minKn, accuracy: 0.0001)  // min of samples IS minKn by construction
```

- [ ] **Step 2: Run to verify failure**

Run: `cd watch/StallAlertKit && swift test 2>&1 | tail -5`
Expected: compile FAILURE — `cannot find 'TrendlineModel' in scope` (and `value of type 'NextHourView' has no member 'samplesKn'`). Capture exact lines.

- [ ] **Step 3: Implement.** Create `TrendlineModel.swift`:

```swift
import Foundation

/// Normalizes the next-hour wind samples plus the alert threshold into
/// [0, 1] y-coordinates for the mini trendline. The range always includes
/// the threshold (so its reference line is in frame) and spans at least
/// 4 kn (so flat forecasts draw flat instead of amplifying sub-knot noise).
public struct TrendlineRender: Equatable, Sendable {
    public let ys: [Double]       // [0, 1], 0 = range bottom; one per sample
    public let thresholdY: Double // same space

    public init(ys: [Double], thresholdY: Double) {
        self.ys = ys
        self.thresholdY = thresholdY
    }
}

public enum TrendlineModel {
    /// nil when there are fewer than 2 samples (nothing to draw).
    public static func render(samplesKn: [Double], thresholdKn: Double) -> TrendlineRender? {
        guard samplesKn.count >= 2 else { return nil }
        var lo = min(samplesKn.min()!, thresholdKn)
        var hi = max(samplesKn.max()!, thresholdKn)
        if hi - lo < 4 {
            let mid = (hi + lo) / 2
            lo = mid - 2
            hi = mid + 2
        }
        let span = hi - lo
        return TrendlineRender(
            ys: samplesKn.map { ($0 - lo) / span },
            thresholdY: (thresholdKn - lo) / span
        )
    }
}
```

In `ForecastEngine.swift`, add the field to `NextHourView` (appended LAST, default keeps existing call sites compiling):

```swift
public struct NextHourView: Equatable, Sendable {
    public let minKn: Double
    public let maxKn: Double
    public let trend: Trend
    public let projectedBaseKn: Double
    public let samplesKn: [Double]
    public init(minKn: Double, maxKn: Double, trend: Trend, projectedBaseKn: Double,
                samplesKn: [Double] = []) {
        self.minKn = minKn; self.maxKn = maxKn; self.trend = trend
        self.projectedBaseKn = projectedBaseKn; self.samplesKn = samplesKn
    }
}
```

and pass the samples in `nextHour`'s return:

```swift
return NextHourView(minKn: bases.min()!, maxKn: gusts.max()!, trend: trend,
                    projectedBaseKn: baseNext, samplesKn: bases)
```

- [ ] **Step 4: Run to verify pass**

Run: `cd watch/StallAlertKit && swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 84 existing + 5 new = 89 tests, 0 failures; zero warnings in full output.

- [ ] **Step 5: Commit**

```bash
git add watch/StallAlertKit && git commit -m "feat(watch): next-hour wind samples and trendline render model"
```

---

### Task 2: TrendlineView on both screens (+ checklist)

**Files:**
- Modify: `watch/App/Views/StartView.swift` (placement + new internal view replacing `trendSymbol`)
- Modify: `watch/App/Views/SessionView.swift:14-16` (placement)
- Modify: `docs/hardware-checklist.md` (append section)

**Interfaces:**
- Consumes: `TrendlineModel.render(samplesKn:thresholdKn:) -> TrendlineRender?` and `NextHourView.samplesKn` (Task 1); each screen's existing threshold/color context.
- Produces: UI only.

- [ ] **Step 1: StartView.** Replace the whole file body as follows — the `if let nh` branch swaps the arrow text for an HStack, and `trendSymbol` at the bottom of the file is REPLACED by `TrendlineView`:

```swift
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
```

(`trendSymbol(_:)` must no longer exist anywhere; the `Trend` enum import/usage elsewhere stays.)

- [ ] **Step 2: SessionView.** In the NEXT HOUR block, replace

```swift
Text("\(Int(nh.minKn.rounded()))–\(Int(nh.maxKn.rounded())) kn \(trendSymbol(nh.trend))")
    .font(.title2).bold()
    .foregroundStyle(color(for: nh.minKn))
```

with

```swift
HStack(spacing: 6) {
    Text("\(Int(nh.minKn.rounded()))–\(Int(nh.maxKn.rounded())) kn")
        .font(.title2).bold()
        .foregroundStyle(color(for: nh.minKn))
    TrendlineView(samplesKn: nh.samplesKn,
                  thresholdKn: session.settings.thresholdKn,
                  tint: color(for: nh.minKn))
}
```

The `if nh.trend == .dropping` caption below it stays untouched.

- [ ] **Step 3: Build + suite + scheme guard.**

Run:
```bash
grep -c STALLALERT_ watch/StallAlert.xcodeproj/xcshareddata/xcschemes/StallAlert.xcscheme   # expect 4
xcodebuild -project watch/StallAlert.xcodeproj -scheme StallAlert -destination 'generic/platform=watchOS Simulator' build 2>&1 | tail -3
cd watch/StallAlertKit && swift test 2>&1 | grep -E "Executed .* tests" | tail -1
grep -c STALLALERT_ ../StallAlert.xcodeproj/xcshareddata/xcschemes/StallAlert.xcscheme       # expect 4 (unchanged)
```
Expected: `BUILD SUCCEEDED`; 89 tests, 0 failures; both greps print `4`.

- [ ] **Step 4: Checklist.** Append to `docs/hardware-checklist.md`:

```markdown

## Next-hour trendline (added 2026-07-11)
- [ ] The trend arrow is gone on BOTH the start screen and the session
      screen; a small line graph sits right of the kn range instead.
- [ ] When the forecast is dropping, the line slopes down toward the
      faint red dashed threshold line.
- [ ] Flat forecast draws a near-flat line (no exaggerated wiggle).
- [ ] The graph's color matches the numbers next to it (tinted on the
      session screen, plain on the start screen).
```

- [ ] **Step 5: Commit**

```bash
git add watch docs && git commit -m "feat(watch): next-hour trendline replaces trend arrow on both screens"
```
