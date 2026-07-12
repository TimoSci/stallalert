# NEXT HOUR Forecast-Direction Arrow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A small compass dial (rim + downwind arrow, no history ticks) right of the NEXT HOUR mini-graph on both screens, showing the vector-mean forecast direction for the same hour, tinted like the numbers.

**Architecture:** Spec 2026-07-13-forecast-direction-arrow-design.md. `ForecastEngine.nextHour` gains `dirDeg: Double?` (vector-mean of seam-safe vectorially-interpolated directions at the existing 7 sample times; near-zero resultant → nil). `CompassModel`'s private `normalizeDownwind` becomes public `downwindAngle(fromDeg:)` (pure extraction). `ForecastArrowView` joins `TrendlineView` in `StartView.swift`; both NEXT HOUR HStacks append it, and the numbers Text gains the width guard.

**Tech Stack:** existing — Swift 6 strict-concurrency StallAlertKit package + SwiftUI watch app. No new dependencies. No server changes.

## Global Constraints

- Direction math: unit vector = `(sin θ, cos θ)` of meteorological FROM-degrees; within-step interpolation lerps the components by the scalar time fraction, `atan2(x, y)` back, +360 if negative; a near-zero interpolated vector (`x² + y² <= 1.0e-18`, antipodal midpoint) skips that sample; the hour's mean sums the sample unit vectors and yields nil when the resultant magnitude < 1.0e-9.
- `NextHourView.dirDeg: Double?` appended LAST with `= nil` default — existing call sites and committed tests compile unchanged.
- `CompassModel.downwindAngle(fromDeg:)` = `(deg + 180).truncatingRemainder(dividingBy: 360)`, +360 if negative — a PURE extraction of the existing private `normalizeDownwind`; all existing CompassModel tests must pass unchanged.
- View: dial 22 pt; rim `Circle().stroke(.secondary.opacity(0.3), lineWidth: 1)` (neutral, like the station dial); arrow `location.north.fill` at `size * 0.45`, rotated by `downwindAngle`, `.foregroundStyle(tint)`; omitted when `dirDeg` nil.
- Width guard: `.lineLimit(1).minimumScaleFactor(0.8)` on the NEXT HOUR numbers Text, BOTH screens.
- **NO new app-target files** → NO xcodegen; scheme guard: `grep -c STALLALERT_ watch/StallAlert.xcodeproj/xcshareddata/xcschemes/StallAlert.xcscheme` prints `4` before AND after.
- Watch norms: `cd watch/StallAlertKit && swift test` zero failures, zero warnings; app builds via `xcodebuild -project watch/StallAlert.xcodeproj -scheme StallAlert -destination 'generic/platform=watchOS Simulator' build`.
- Branch: `forecast-direction-arrow` off `main`.

---

### Task 1: Package — dirDeg vector mean + downwindAngle extraction

**Files:**
- Modify: `watch/StallAlertKit/Sources/StallAlertKit/ForecastEngine.swift`
- Modify: `watch/StallAlertKit/Sources/StallAlertKit/CompassModel.swift:34,68,78-83`
- Test: `watch/StallAlertKit/Tests/StallAlertKitTests/ForecastEngineTests.swift` (extend), `watch/StallAlertKit/Tests/StallAlertKitTests/CompassModelTests.swift` (extend)

**Interfaces:**
- Consumes: existing `interpolate(_:at:value:)` pattern and the 7-sample grid in `nextHour`.
- Produces (Task 2 relies on these exact names):

```swift
// NextHourView gains, appended LAST: public let dirDeg: Double?
//   init(..., dirDeg: Double? = nil)
// CompassModel gains:
public static func downwindAngle(fromDeg deg: Double) -> Double  // [0, 360)
```

- [ ] **Step 1: Write the failing tests.** In `CompassModelTests.swift` add:

```swift
    func testDownwindAngleWraparound() {
        XCTAssertEqual(CompassModel.downwindAngle(fromDeg: 350), 170)
        XCTAssertEqual(CompassModel.downwindAngle(fromDeg: 90), 270)
        XCTAssertEqual(CompassModel.downwindAngle(fromDeg: 180), 0)
        XCTAssertEqual(CompassModel.downwindAngle(fromDeg: 0), 180)
    }
```

In `ForecastEngineTests.swift` add three tests. READ the file's existing helper for building a `Forecast`/`WindStep` list first and reuse it (the code below shows intent with explicit construction; adapt to the file's existing fixture helpers, keeping the assertions verbatim):

```swift
    func testDirDegConstantDirection() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let steps = [
            WindStep(time: now, windKn: 10, gustKn: 12, dirDeg: 90),
            WindStep(time: now.addingTimeInterval(3600), windKn: 10, gustKn: 12, dirDeg: 90),
        ]
        let nh = ForecastEngine.nextHour(from: Forecast(model: "t", hours: steps), at: now)!
        XCTAssertEqual(nh.dirDeg!, 90, accuracy: 0.0001)
    }

    func testDirDegNorthSeamAveragesToZero() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let steps = [
            WindStep(time: now, windKn: 10, gustKn: 12, dirDeg: 350),
            WindStep(time: now.addingTimeInterval(3600), windKn: 10, gustKn: 12, dirDeg: 10),
        ]
        let nh = ForecastEngine.nextHour(from: Forecast(model: "t", hours: steps), at: now)!
        let d = nh.dirDeg!
        // mean must sit at the seam (0°/360°), never anywhere near 180
        XCTAssertTrue(d < 0.1 || d > 359.9, "expected ~0, got \(d)")
    }

    func testDirDegOpposingDirectionsIsNil() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let steps = [
            WindStep(time: now, windKn: 10, gustKn: 12, dirDeg: 0),
            WindStep(time: now.addingTimeInterval(3600), windKn: 10, gustKn: 12, dirDeg: 180),
        ]
        let nh = ForecastEngine.nextHour(from: Forecast(model: "t", hours: steps), at: now)!
        // 0° and 180° in equal measure cancel: 3 samples each side of the
        // antipodal midpoint (which itself yields no vector) -> nil
        XCTAssertNil(nh.dirDeg)
    }
```

(If `Forecast`'s init differs — e.g. extra fields — match the existing tests' construction; the `WindStep` values and all assertions are binding.)

- [ ] **Step 2: Run to verify failure**

Run: `cd watch/StallAlertKit && swift test 2>&1 | tail -5`
Expected: compile FAILURE — `type 'CompassModel' has no member 'downwindAngle'` / `has no member 'dirDeg'`. Capture exact lines.

- [ ] **Step 3: Implement.**

(a) `CompassModel.swift` — pure extraction: replace the private helper

```swift
    /// Normalizes a meteorological FROM-direction to a downwind TO-direction.
    /// Formula: (fromDeg + 180) % 360, with special handling for negative remainders.
    /// Public so other downwind renderings (e.g. the forecast arrow) share one implementation.
    public static func downwindAngle(fromDeg: Double) -> Double {
        let downwind = (fromDeg + 180).truncatingRemainder(dividingBy: 360)
        return downwind < 0 ? downwind + 360 : downwind
    }
```

and change the two internal call sites (`CompassModel.swift:34` and `:68`) from `normalizeDownwind(...)` to `downwindAngle(fromDeg: ...)`. No other change to `render`.

(b) `ForecastEngine.swift` — `NextHourView` gains the field (appended LAST):

```swift
public struct NextHourView: Equatable, Sendable {
    public let minKn: Double
    public let maxKn: Double
    public let trend: Trend
    public let projectedBaseKn: Double
    public let samplesKn: [Double]
    public let dirDeg: Double?
    public init(minKn: Double, maxKn: Double, trend: Trend, projectedBaseKn: Double,
                samplesKn: [Double] = [], dirDeg: Double? = nil) {
        self.minKn = minKn; self.maxKn = maxKn; self.trend = trend
        self.projectedBaseKn = projectedBaseKn; self.samplesKn = samplesKn
        self.dirDeg = dirDeg
    }
}
```

In `nextHour`, after the existing sampling loop, compute the vector mean and thread it into the return:

```swift
        // Vector-mean forecast direction over the same window (seam-safe);
        // samples whose interpolation is antipodal-degenerate are skipped,
        // and a near-zero resultant (genuinely turning wind) yields nil.
        var vx = 0.0, vy = 0.0
        for t in samples {
            if let d = interpolateDirection(steps, at: t) {
                vx += sin(d * .pi / 180)
                vy += cos(d * .pi / 180)
            }
        }
        let dirDeg: Double?
        if (vx * vx + vy * vy).squareRoot() < 1.0e-9 {
            dirDeg = nil
        } else {
            var deg = atan2(vx, vy) * 180 / .pi
            if deg < 0 { deg += 360 }
            dirDeg = deg
        }
        return NextHourView(minKn: bases.min()!, maxKn: gusts.max()!, trend: trend,
                            projectedBaseKn: baseNext, samplesKn: bases, dirDeg: dirDeg)
```

(replacing the existing `return NextHourView(...)` line) and add the private helper below the existing `interpolate`:

```swift
    /// Direction interpolation must be vectorial: lerping raw degrees breaks
    /// at the north seam (350 -> 10 would pass through 180). Lerp the unit
    /// vectors by the same time fraction instead; an antipodal midpoint has
    /// no defined direction and returns nil (the sample is skipped).
    private static func interpolateDirection(_ steps: [WindStep], at t: Date) -> Double? {
        guard let first = steps.first, let last = steps.last,
              t >= first.time, t <= last.time else { return nil }
        if let exact = steps.first(where: { $0.time == t }) { return exact.dirDeg }
        guard let after = steps.first(where: { $0.time > t }),
              let before = steps.last(where: { $0.time < t }) else { return nil }
        let span = after.time.timeIntervalSince(before.time)
        let frac = t.timeIntervalSince(before.time) / span
        let b = before.dirDeg * .pi / 180, a = after.dirDeg * .pi / 180
        let x = sin(b) * (1 - frac) + sin(a) * frac
        let y = cos(b) * (1 - frac) + cos(a) * frac
        guard x * x + y * y > 1.0e-18 else { return nil }
        var deg = atan2(x, y) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `cd watch/StallAlertKit && swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 89 existing + 4 new = 93 tests, 0 failures; zero warnings in full output. Every pre-existing CompassModel and ForecastEngine test passes UNCHANGED (extraction proof).

- [ ] **Step 5: Commit**

```bash
git add watch/StallAlertKit && git commit -m "feat(watch): vector-mean forecast direction and shared downwind angle"
```

---

### Task 2: ForecastArrowView on both screens (+ width guard + checklist)

**Files:**
- Modify: `watch/App/Views/StartView.swift` (HStack + new internal view below TrendlineView)
- Modify: `watch/App/Views/SessionView.swift` (NEXT HOUR HStack)
- Modify: `docs/hardware-checklist.md` (append section)

**Interfaces:**
- Consumes: `NextHourView.dirDeg: Double?`, `CompassModel.downwindAngle(fromDeg:) -> Double` (Task 1), `TrendlineView` (existing).
- Produces: UI only.

- [ ] **Step 1: StartView.** In the NEXT HOUR HStack, the numbers Text gains the width guard and the arrow appends after `TrendlineView`:

```swift
                HStack(spacing: 6) {
                    Text("\(Int(nh.minKn.rounded()))–\(Int(nh.maxKn.rounded())) kn")
                        .font(.title3)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    TrendlineView(samplesKn: nh.samplesKn,
                                  thresholdKn: session.settings.thresholdKn,
                                  tint: .primary)
                    if let d = nh.dirDeg {
                        ForecastArrowView(dirDeg: d, tint: .primary)
                    }
                }
```

At the bottom of the file, below `TrendlineView`, add:

```swift
/// Forecast wind-direction dial: the station compass's rim and downwind
/// arrow (via the shared CompassModel.downwindAngle), without history
/// ticks. The arrow — not the rim — takes the NEXT HOUR tint so it reads
/// as part of the forecast row. Lives here beside TrendlineView so no new
/// app-target file forces an xcodegen run.
struct ForecastArrowView: View {
    let dirDeg: Double
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.3), lineWidth: 1)
            Image(systemName: "location.north.fill")
                .font(.system(size: size * 0.45))
                .rotationEffect(.degrees(CompassModel.downwindAngle(fromDeg: dirDeg)))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}
```

- [ ] **Step 2: SessionView.** The NEXT HOUR HStack becomes:

```swift
                    HStack(spacing: 6) {
                        Text("\(Int(nh.minKn.rounded()))–\(Int(nh.maxKn.rounded())) kn")
                            .font(.title2).bold()
                            .foregroundStyle(color(for: nh.minKn))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        TrendlineView(samplesKn: nh.samplesKn,
                                      thresholdKn: session.settings.thresholdKn,
                                      tint: color(for: nh.minKn))
                        if let d = nh.dirDeg {
                            ForecastArrowView(dirDeg: d, tint: color(for: nh.minKn))
                        }
                    }
```

The `.dropping` caption below stays untouched; nothing else in the file changes.

- [ ] **Step 3: Build + suite + scheme guard.**

Run:
```bash
grep -c STALLALERT_ watch/StallAlert.xcodeproj/xcshareddata/xcschemes/StallAlert.xcscheme   # expect 4
xcodebuild -project watch/StallAlert.xcodeproj -scheme StallAlert -destination 'generic/platform=watchOS Simulator' build 2>&1 | tail -3
cd watch/StallAlertKit && swift test 2>&1 | grep -E "Executed .* tests" | tail -1
grep -c STALLALERT_ ../StallAlert.xcodeproj/xcshareddata/xcschemes/StallAlert.xcscheme       # expect 4 (unchanged)
```
Expected: `BUILD SUCCEEDED`; 93 tests, 0 failures; both greps print `4`.

- [ ] **Step 4: Checklist.** Append to `docs/hardware-checklist.md`:

```markdown

## Forecast direction arrow (added 2026-07-13)
- [ ] A small dial with an arrow sits right of the NEXT HOUR mini-graph on
      BOTH screens; the arrow matches windguru.cz's forecast direction for
      the spot (downwind convention, same as the station arrow below).
- [ ] The arrow is tinted like the NEXT HOUR numbers (colored on the
      session screen, plain on the start screen); the rim stays faint gray.
- [ ] The NEXT HOUR numbers never wrap to two lines (they shrink slightly
      instead if space is tight).
```

- [ ] **Step 5: Commit**

```bash
git add watch docs && git commit -m "feat(watch): forecast direction dial beside the next-hour trendline"
```
