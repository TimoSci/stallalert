# Wind Compass with Direction History — Design Spec

**Date:** 2026-07-09
**Status:** Approved design, pre-implementation
**Extends:** 2026-07-06-stallalert-design.md, 2026-07-08-station-override-design.md

## Purpose

Wind direction is load-bearing for kitesurfing (onshore vs offshore changes
what a wind drop means) but is currently not displayed anywhere. Add a small
compass dial next to the live wind in the session screen's NOW block: a solid
arrow for the current direction plus slowly fading "shadow" ticks for the
directions of the last hour — so a wind shift is visible as a trail sweeping
around the rim.

## Decisions (made with the user)

| Decision | Choice |
|---|---|
| Arrow convention | Points **downwind** (where the air is going) — Windguru arrow convention; data is meteorological FROM-degrees, so arrow angle = `dirDeg + 180°` normalized |
| Shadow style | **Fading tick marks** on the dial rim, one per past sample; newest ~0.6 opacity, fading linearly to 0 at 60 minutes; honest about ~5-min sampling |
| History source | **Server-supplied**: the `q=station_data` window (last 60 min, ~12 samples) is already downloaded per refresh; the server stops discarding the non-newest samples and ships them. Zero extra Windguru traffic; full trail from a session's first tick. Direct-fallback client supplies the identical field from the same window it already parses. |

## Server changes (`server/`)

- `StationParser`: in addition to the max-unixtime reading, extract the
  window's usable samples (same nil-skip + equal-length rules as today) as
  `direction_history: [%{time: DateTime.t(), dir_deg: float}]`, ascending by
  time, embedded IN the reading map returned by `parse_reading/1` (the
  reading gains one key; the map shape is otherwise unchanged).
- Adapter/Conditions/serializer: **no structural changes** — the history
  rides inside `station.reading` through the existing cache and serializes
  automatically as `"direction_history": [{"time": ISO-8601, "dir_deg": 220.0}, ...]`.
  Backward-compatible addition (~12 entries).
- `FakeAdapter`: default reading gains a 3-sample history.
- Tests: parser extraction incl. nil-sample skipping inside the window;
  ascending order; wire shape via router test; existing reading semantics
  (max-unixtime selection, mismatch rejection) unchanged.

## Watch changes (`watch/`)

### StallAlertKit

- **Models:** `DirectionSample { time: Date, dirDeg: Double }` (Codable/
  Equatable/Sendable); `StationReading` gains
  `directionHistory: [DirectionSample]?` — optional, `= nil` init default,
  appended LAST in the memberwise init (existing call sites unchanged; old
  payloads/fixtures decode with nil).
- **DirectWindguruClient:** populates `directionHistory` from the windowed
  samples it already parses (ascending, nil-skipped) — parity with the
  server; zero extra HTTP.
- **`CompassModel`** (new, pure, fully unit-tested):
  `render(reading: StationReading, now: Date) -> CompassRender` where
  `CompassRender { arrowAngleDeg: Double, ticks: [(angleDeg: Double, opacity: Double)] }`.
  - Arrow: `(reading.dirDeg + 180).truncatingRemainder(dividingBy: 360)`
    (normalized to [0, 360)).
  - Ticks: for each history sample except any with `time == reading.time`
    (that one IS the arrow): angle = downwind-normalized like the arrow;
    opacity = `0.6 * max(0, 1 - age/3600)` with `age = now - sample.time`;
    samples with age >= 3600 s dropped (exact-hour boundary excluded so opacity is never 0); duplicate timestamps deduped.
  - Wraparound math (350° + 180° → 170°) pinned by tests.

### App layer

- **`CompassView`** (~30 pt): faint rim circle; a short tick at each shadow
  angle with its opacity; a solid arrow (custom triangle path or SF symbol,
  rotated) for the current direction. Renders from `CompassModel.render`.
- Placement: in the NOW block's HStack, right of the wind/gust numbers.
- Stale reading (> 20 min): the whole dial grays out exactly like the
  numbers (same age check already used there). No reading → no compass.
  No/nil history → arrow only, no ticks.

## Error handling

- Missing `direction_history` (old server) → arrow-only compass; nothing
  breaks (optional decode).
- Empty window / all-nil direction samples → arrow only.
- All error/staleness behavior of readings is unchanged; the compass adds
  no new failure modes to fetch/alerting paths (AlertPolicy untouched).

## Testing

- Server (ExUnit): parser history extraction (real fixture: expect the
  window's 12 samples ascending), nil-skip inside window, wire shape.
- Watch (XCTest): decode with/without the new field; CompassModel — downwind
  wraparound, opacity fade endpoints (fresh ≈ 0.6, 59 min ≈ small, 61 min
  dropped), current-reading exclusion, timestamp dedupe.
- Build + simulator screenshot; hardware checklist: compass visible next to
  live wind, arrow matches windguru.cz's direction for the station, shadows
  fade over the session, dial grays out with a stale reading.

## Out of scope

Forecast-direction display; onshore/offshore classification (needs beach
orientation data); compass on the start screen; animating tick transitions.
