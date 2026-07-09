# Wind Compass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A small compass dial next to the live wind: downwind arrow for the current direction, fading rim ticks for the past hour's directions — history supplied by the server from the station-data window it already downloads.

**Architecture:** Spec 2026-07-09-wind-compass-design.md. Server: `StationParser.parse_reading/1`'s returned reading map gains `direction_history` (the window's usable samples, ascending) — nothing else server-side changes structurally (history rides through the cache and serializes automatically). Watch: optional `StationReading.directionHistory` decode + direct-client parity + pure `CompassModel` (angle/opacity math) + `CompassView` in the NOW block.

**Tech Stack:** existing — Elixir server, Swift 6 strict-concurrency watch package + SwiftUI app. No new dependencies.

## Global Constraints

- Arrow angle = **downwind**: `(dirDeg + 180)` normalized to `[0, 360)`. Data is meteorological FROM-degrees.
- Tick opacity = `0.6 * max(0, 1 - age/3600)`; samples older than **3600 s** dropped; the sample whose `time == reading.time` is EXCLUDED from ticks (it is the arrow); duplicate timestamps deduped.
- `direction_history`: ascending by time, only fully-populated samples (same nil-skip + equal-length rules as the existing reading parse), embedded in the reading map / `StationReading`.
- All new fields optional/backward-compatible: old payloads and committed fixtures must decode unchanged; new init params appended LAST with `= nil` defaults.
- Server norms: `mix test --warnings-as-errors` + `mix format --check-formatted` green; watch norms: `swift test` zero warnings; app builds via `xcodebuild ... -destination 'generic/platform=watchOS Simulator'`.
- **Task 5 regenerates the Xcode project** (new app source file) — the scheme-preservation ritual applies (back up `StallAlert.xcscheme`, restore after, `grep -c STALLALERT_` → 4).

---

### Task 1: Server — direction history in the parsed reading

**Files:**
- Modify: `server/lib/stallalert/windguru/station_parser.ex`
- Modify: `server/test/support/fake_adapter.ex` (default reading gains 3-sample history; keys covered by existing reset)
- Test: `server/test/stallalert/windguru/station_parser_test.exs` (extend), `server/test/stallalert/router_test.exs` (one wire-shape assertion)

**Interfaces:**
- Produces: `parse_reading/1` returns `{:ok, %{time:, wind_kn:, gust_kn:, dir_deg:, direction_history: [%{time: DateTime.t(), dir_deg: float}]}}` — history ascending by time, built from the SAME usable samples the max-unixtime selection already computes (nil-skipped, equal-length-guarded). All existing keys/semantics unchanged. The wire payload gains `station.reading.direction_history` automatically (Jason encodes the map; DateTime → ISO-8601).

- [ ] **Step 1: Failing tests.** In `station_parser_test.exs`: extend the real-fixture test — `assert [%{time: %DateTime{}, dir_deg: _} | _] = r.direction_history`, `assert length(r.direction_history) == 12` (the fixture window has 12 samples — verify by reading the fixture and adjust to the true count of fully-populated samples), ascending: `assert r.direction_history == Enum.sort_by(r.direction_history, & &1.time, DateTime)`, and the LAST history entry's time equals `r.time` (the newest sample is both). Extend the existing nil-sample synthetic test: the nil-valued sample must be absent from `direction_history` too. In `router_test.exs`: extend the 200-payload test — `assert [%{"time" => _, "dir_deg" => _} | _] = body["station"]["reading"]["direction_history"]`.
- [ ] **Step 2: Run to verify failure** (`cd server && mix test test/stallalert/windguru/station_parser_test.exs test/stallalert/router_test.exs`).
- [ ] **Step 3: Implement.** In `parse_reading/1`, the usable-samples list already exists before `max_by`; map it to `%{time: DateTime.from_unix!(t), dir_deg: dir * 1.0}` sorted ascending and `Map.put` it on the returned reading. Update FakeAdapter's default reading with `direction_history: [three entries ~10/5/0 min before its time, ascending, last entry time == reading time]`.
- [ ] **Step 4: Full suite + format green** (`mix test --warnings-as-errors && mix format --check-formatted`).
- [ ] **Step 5: Commit** — `git add server && git commit -m "feat(server): direction history in station reading"`

---

### Task 2: Watch — models decode

**Files:**
- Modify: `watch/StallAlertKit/Sources/StallAlertKit/Models.swift`
- Test: `watch/StallAlertKit/Tests/StallAlertKitTests/ModelsTests.swift` (extend)

**Interfaces:**
- Produces:

```swift
public struct DirectionSample: Codable, Equatable, Sendable {
    public let time: Date
    public let dirDeg: Double
    public init(time: Date, dirDeg: Double)
}
// StationReading gains, appended LAST with default:
//   public let directionHistory: [DirectionSample]?
//   init(..., directionHistory: [DirectionSample]? = nil)
```

- [ ] **Step 1: Failing tests.** (a) existing `conditions.json` fixture decodes with `station?.reading?.directionHistory == nil`; (b) inline JSON reading with a 2-entry `"direction_history"` (snake_case, ISO times) decodes to exact `DirectionSample` values.
- [ ] **Step 2: verify failure → Step 3: implement → Step 4: full `swift test` green (existing tests unchanged) → Step 5: Commit** — `git add watch && git commit -m "feat(watch): decode direction history"`

---

### Task 3: Watch — direct-client parity

**Files:**
- Modify: `watch/StallAlertKit/Sources/StallAlertKit/DirectWindguruClient.swift`
- Test: `watch/StallAlertKit/Tests/StallAlertKitTests/DirectWindguruClientTests.swift` (extend)

**Interfaces:**
- Consumes: the windowed-sample parsing already inside the client's station-reading path (nil-skip, equal-length guard, max-unixtime).
- Produces: readings built by the direct client carry `directionHistory` (ascending, nil-skipped, same rules as the server) — identical field the picker/compass consume regardless of data path.

- [ ] **Step 1: Failing test.** Extend the happy-path fetch test: `station.reading?.directionHistory` non-nil, count matches the real `station_current.json` fixture's fully-populated sample count (read the fixture — 12 samples, verify), ascending, last entry time == reading.time. Extend the existing nil-sample synthetic test: nil sample absent from history.
- [ ] **Step 2: verify failure → Step 3: implement** (the parse already iterates the usable samples; collect them into `[DirectionSample]` sorted ascending and pass into the `StationReading` init) **→ Step 4: full `swift test` green → Step 5: Commit** — `git add watch && git commit -m "feat(watch): direct-path direction history parity"`

---

### Task 4: Watch — CompassModel (pure math)

**Files:**
- Create: `watch/StallAlertKit/Sources/StallAlertKit/CompassModel.swift`
- Test: `watch/StallAlertKit/Tests/StallAlertKitTests/CompassModelTests.swift`

**Interfaces:**
- Produces:

```swift
public struct CompassRender: Equatable, Sendable {
    public let arrowAngleDeg: Double                      // downwind, [0, 360)
    public let ticks: [Tick]
    public struct Tick: Equatable, Sendable {
        public let angleDeg: Double                       // downwind, [0, 360)
        public let opacity: Double                        // (0, 0.6]
    }
}
public enum CompassModel {
    public static func render(reading: StationReading, now: Date) -> CompassRender
}
```

- [ ] **Step 1: Failing tests** (exact values):

```swift
func testDownwindWraparound()      // dirDeg 350 -> arrow 170; dirDeg 90 -> 270; dirDeg 180 -> 0
func testTickOpacityFade()         // sample 0 s old (but time != reading.time) -> 0.6; 1800 s -> 0.3 (accuracy 0.001); 3599 s -> ~0.0002 present; 3601 s -> dropped
func testCurrentReadingExcluded()  // history entry with time == reading.time produces NO tick
func testDuplicateTimestampsDeduped() // two entries same time -> one tick
func testNilHistoryMeansNoTicks()  // directionHistory nil -> ticks == []
```

- [ ] **Step 2: verify failure → Step 3: implement** (single static func: normalize `(deg + 180).truncatingRemainder(dividingBy: 360)`, add 360 if negative; filter/dedupe/map per Global Constraints) **→ Step 4: full `swift test` green → Step 5: Commit** — `git add watch && git commit -m "feat(watch): compass render model"`

---

### Task 5: Watch — CompassView + NOW-block placement (+ checklist)

**Files:**
- Create: `watch/App/Views/CompassView.swift`
- Modify: `watch/App/Views/SessionView.swift` (NOW block HStack)
- Modify: `docs/hardware-checklist.md` (compass section)
- Regenerate: `watch/StallAlert.xcodeproj` (scheme ritual per Global Constraints)

**Interfaces:**
- Consumes: `CompassModel.render`, the NOW block's existing staleness check (`ageSeconds(r) > 20 * 60`).

- [ ] **Step 1: CompassView** (complete):

```swift
import SwiftUI
import StallAlertKit

struct CompassView: View {
    let reading: StationReading
    let stale: Bool
    var size: CGFloat = 30

    var body: some View {
        let render = CompassModel.render(reading: reading, now: Date())
        ZStack {
            Circle().stroke(.secondary.opacity(0.3), lineWidth: 1)
            ForEach(Array(render.ticks.enumerated()), id: \.offset) { _, tick in
                Capsule()
                    .fill(.primary.opacity(tick.opacity))
                    .frame(width: 1.5, height: size * 0.18)
                    .offset(y: -size * 0.41)
                    .rotationEffect(.degrees(tick.angleDeg))
            }
            Image(systemName: "location.north.fill")
                .font(.system(size: size * 0.45))
                .rotationEffect(.degrees(render.arrowAngleDeg))
        }
        .frame(width: size, height: size)
        .foregroundStyle(stale ? .secondary : .primary)
        .grayscale(stale ? 1 : 0)
    }
}
```

- [ ] **Step 2: Placement.** In `SessionView`'s NOW block, wrap the wind-numbers `Text` and the compass in an `HStack(spacing: 8)`: numbers as today, then `CompassView(reading: r, stale: ageSeconds(r) > 20 * 60)`. Keep the block's Button/pin/age logic untouched.
- [ ] **Step 3: Scheme ritual + regenerate + build.** Back up the scheme, `cd watch && xcodegen generate`, restore, `grep -c STALLALERT_ ...xcscheme` → 4; `xcodebuild ... build` → BUILD SUCCEEDED; `cd StallAlertKit && swift test` → all green.
- [ ] **Step 4: Checklist.** Append to `docs/hardware-checklist.md`:

```markdown

## Wind compass (added 2026-07-09)
- [ ] Compass dial appears next to the live wind numbers; arrow direction
      matches windguru.cz's arrow for the station (downwind convention).
- [ ] Shadow ticks visible from the FIRST tick of a session (server ships
      the past hour); they fade as the session progresses.
- [ ] Stale reading (> 20 min): the whole dial grays out with the numbers.
- [ ] Direct-fallback mode (server stopped): compass + shadows still render.
```

- [ ] **Step 5: Commit** — `git add watch docs && git commit -m "feat(watch): compass dial with direction-shadow ticks in NOW block"`
