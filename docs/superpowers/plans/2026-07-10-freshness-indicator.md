# Tap-to-Refresh + Freshness Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tapping the live-wind numbers or the age line forces a refresh; the age line flashes greyish-green on a new station sample, fades to gray over 5 min, and a dotted track's `<` marker travels to the screen edge over 15 min, then becomes a clock symbol.

**Architecture:** Spec 2026-07-10-freshness-indicator-design.md. One pure function (`FreshnessModel.render`, StallAlertKit, CompassModel precedent) maps `readingTime`/`now` to `{greenness, markerFraction, showClock}`. SessionView splits the NOW block's single button into a picker row and a refresh row and renders the freshness line inside a `TimelineView` — all app-side changes stay inside the existing `SessionView.swift` (no new app-target file).

**Tech Stack:** existing — Swift 6 strict-concurrency StallAlertKit package + SwiftUI watch app. No new dependencies. No server changes.

## Global Constraints

- Clock source: `age = max(0, now − reading.time)` — a new sample lowers the age; no stored fetch state.
- `greenness = max(0, 1 − age/300)`; `markerFraction = min(age/900, 1)`; `showClock = age >= 900`.
- Edge symbol: SF Symbol `clock`. Marker: SF Symbol `chevron.left`.
- Tap feedback: `WKInterfaceDevice.current().play(.click)`; freshness line at 40 % opacity while the tapped fetch is in flight; no spinner.
- Text color endpoints: clearly green-tinted at `greenness == 1`, the current `.secondary`-like gray at `0` (`Color(hue: 0.36, saturation: 0.35 * greenness, brightness: 0.75)` is the reference implementation).
- **NO new app-target files** → NO xcodegen regeneration; the scheme must be untouched: `grep -c STALLALERT_ watch/StallAlert.xcodeproj/xcshareddata/xcschemes/StallAlert.xcscheme` must print `4` before AND after.
- Watch norms: `cd watch/StallAlertKit && swift test` zero failures, zero warnings; app builds via `xcodebuild -project watch/StallAlert.xcodeproj -scheme StallAlert -destination 'generic/platform=watchOS Simulator' build`.
- Branch: `freshness-indicator` off `main`.

---

### Task 1: FreshnessModel (pure math, package)

**Files:**
- Create: `watch/StallAlertKit/Sources/StallAlertKit/FreshnessModel.swift`
- Test: `watch/StallAlertKit/Tests/StallAlertKitTests/FreshnessModelTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces (Task 2 relies on these exact names):

```swift
public struct FreshnessRender: Equatable, Sendable {
    public let greenness: Double       // [0, 1]; 1 = brand-new reading
    public let markerFraction: Double  // [0, 1]; position along the track
    public let showClock: Bool         // marker replaced by clock symbol
    public init(greenness: Double, markerFraction: Double, showClock: Bool)
}
public enum FreshnessModel {
    public static func render(readingTime: Date, now: Date) -> FreshnessRender
}
```

- [ ] **Step 1: Write the failing tests** — create `FreshnessModelTests.swift`:

```swift
import XCTest
@testable import StallAlertKit

final class FreshnessModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func render(age: TimeInterval) -> FreshnessRender {
        FreshnessModel.render(readingTime: t0, now: t0.addingTimeInterval(age))
    }

    func testBrandNewReading() {
        let f = render(age: 0)
        XCTAssertEqual(f.greenness, 1.0)
        XCTAssertEqual(f.markerFraction, 0.0)
        XCTAssertFalse(f.showClock)
    }

    func testHalfFadedAt150Seconds() {
        let f = render(age: 150)
        XCTAssertEqual(f.greenness, 0.5, accuracy: 0.0001)
        XCTAssertEqual(f.markerFraction, 150.0 / 900.0, accuracy: 0.0001)
        XCTAssertFalse(f.showClock)
    }

    func testFullyGrayAtFiveMinutes() {
        XCTAssertEqual(render(age: 300).greenness, 0.0)
        XCTAssertEqual(render(age: 400).greenness, 0.0) // clamped, not negative
    }

    func testJustBeforeClock() {
        let f = render(age: 899)
        XCTAssertFalse(f.showClock)
        XCTAssertLessThan(f.markerFraction, 1.0)
    }

    func testClockAtFifteenMinutes() {
        let f = render(age: 900)
        XCTAssertTrue(f.showClock)
        XCTAssertEqual(f.markerFraction, 1.0)
        XCTAssertEqual(f.greenness, 0.0)
    }

    func testMarkerCappedPastFifteenMinutes() {
        let f = render(age: 1800)
        XCTAssertTrue(f.showClock)
        XCTAssertEqual(f.markerFraction, 1.0)
    }

    func testFutureReadingClampsToZeroAge() {
        let f = render(age: -60) // clock skew: reading timestamp ahead of now
        XCTAssertEqual(f, render(age: 0))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd watch/StallAlertKit && swift test 2>&1 | tail -5`
Expected: compile FAILURE — `cannot find 'FreshnessModel' in scope` (capture the exact line for the report).

- [ ] **Step 3: Implement** — create `FreshnessModel.swift`:

```swift
import Foundation

/// Freshness of the displayed station reading, keyed purely off the
/// reading's own timestamp: a newer sample lowers the age, which IS the
/// "reset on update" — no stored fetch state (spec 2026-07-10, Decisions).
public struct FreshnessRender: Equatable, Sendable {
    public let greenness: Double       // [0, 1]; 1 = brand-new reading
    public let markerFraction: Double  // [0, 1]; position along the track
    public let showClock: Bool         // marker replaced by clock symbol

    public init(greenness: Double, markerFraction: Double, showClock: Bool) {
        self.greenness = greenness
        self.markerFraction = markerFraction
        self.showClock = showClock
    }
}

public enum FreshnessModel {
    /// Negative ages (reading timestamp ahead of `now` — clock skew)
    /// clamp to 0: full green, marker at the start.
    public static func render(readingTime: Date, now: Date) -> FreshnessRender {
        let age = max(0, now.timeIntervalSince(readingTime))
        return FreshnessRender(
            greenness: max(0, 1 - age / 300),
            markerFraction: min(age / 900, 1),
            showClock: age >= 900
        )
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd watch/StallAlertKit && swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: all tests pass (77 existing + 7 new = 84), 0 failures, zero warnings in the full output.

- [ ] **Step 5: Commit**

```bash
git add watch/StallAlertKit && git commit -m "feat(watch): freshness render model"
```

---

### Task 2: NOW-block tap split + freshness line (+ checklist)

**Files:**
- Modify: `watch/App/Views/SessionView.swift` (whole NOW block, lines ~27–59; new private view; new imports/state)
- Modify: `docs/hardware-checklist.md` (append section)

**Interfaces:**
- Consumes: `FreshnessModel.render(readingTime:now:) -> FreshnessRender` (Task 1), `session.refreshTick()` (existing, `@MainActor`, reentry-safe), `CompassView` (existing).
- Produces: UI only — nothing downstream consumes this.

- [ ] **Step 1: Restructure the NOW block.** In `SessionView.swift`, add `import WatchKit` under `import SwiftUI`, add `@State private var isRefreshing = false` next to `showStationPicker`, and replace the entire `if let st = ... Button { ... } .buttonStyle(.plain)` block (the one wrapping the whole NOW block, currently lines 27–48) with:

```swift
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
}
```

The `else` branch ("No station nearby" picker button) stays byte-identical. Delete the now-unused `ageLabel(_:)` helper (the freshness line renders its own minutes text); keep `ageSeconds(_:)` (still used for staleness).

- [ ] **Step 2: Add the private freshness view.** At the bottom of `SessionView.swift` (below the `SessionView` struct):

```swift
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
```

- [ ] **Step 3: Build + package suite + scheme guard.**

Run:
```bash
grep -c STALLALERT_ watch/StallAlert.xcodeproj/xcshareddata/xcschemes/StallAlert.xcscheme   # expect 4
xcodebuild -project watch/StallAlert.xcodeproj -scheme StallAlert -destination 'generic/platform=watchOS Simulator' build 2>&1 | tail -3
cd watch/StallAlertKit && swift test 2>&1 | grep -E "Executed .* tests" | tail -1
grep -c STALLALERT_ ../StallAlert.xcodeproj/xcshareddata/xcschemes/StallAlert.xcscheme       # expect 4 (unchanged)
```
Expected: `BUILD SUCCEEDED`; 84 tests, 0 failures; both greps print `4`.

- [ ] **Step 4: Checklist.** Append to `docs/hardware-checklist.md`:

```markdown

## Tap-to-refresh + freshness indicator (added 2026-07-10)
- [ ] Tapping the wind numbers or the "updated n min ago" line clicks
      (haptic) and refreshes; the line dims while the fetch is in flight.
- [ ] Tapping the station-name row still opens the station picker.
- [ ] Right after a new station sample the age text is greyish-green; it
      is back to plain gray within ~5 min of no newer sample.
- [ ] The `<` marker sits near the `|` when fresh and reaches the right
      edge at ~15 min without a newer sample, where it becomes a clock
      symbol.
- [ ] With the auto-refresh healthy (5-min cadence) the marker never gets
      far past ~1/3 of the track.
```

- [ ] **Step 5: Commit**

```bash
git add watch docs && git commit -m "feat(watch): tap-to-refresh with reading-freshness line in NOW block"
```
