# Tap-to-Refresh + Reading-Freshness Indicator — Design Spec

**Date:** 2026-07-10
**Status:** Approved design, pre-implementation
**Extends:** 2026-07-06-stallalert-design.md, 2026-07-09-wind-compass-design.md

## Purpose

Give the rider a way to force a refresh from the session screen (tap the
live-wind numbers or the "updated n min ago" line) and make reading
freshness visible at a glance: the age text flashes greyish-green when a
new station sample arrives and fades to the current gray over 5 minutes,
while a thin dotted track to its right shows a `<` marker traveling toward
the screen edge — reaching it at 15 minutes and turning into a clock
symbol.

## Decisions (made with the user)

| Decision | Choice |
|---|---|
| Clock source | **New reading arrival**: everything keys off `age = now − reading.time`. A new station sample lowers the age, which IS the reset — no stored fetch state. (Rejected: last-successful-fetch clock; raw always-gray reading age.) |
| Tap targets | **Split rows**: station-name row keeps opening the station picker; wind numbers + compass + freshness line become the tap-to-refresh target. |
| Edge symbol | SF Symbol `clock` (not `applewatch`). |
| Tap feedback | Light haptic click on tap; the freshness line renders at 40 % opacity while the fetch is in flight; the green flash is the success signal. No spinner. |

## Freshness math (`FreshnessModel`, StallAlertKit, pure)

```swift
public struct FreshnessRender: Equatable, Sendable {
    public let greenness: Double       // [0, 1]; 1 = brand-new reading
    public let markerFraction: Double  // [0, 1]; position along the track
    public let showClock: Bool         // marker replaced by clock symbol
}
public enum FreshnessModel {
    public static func render(readingTime: Date, now: Date) -> FreshnessRender
}
```

- `age = max(0, now − readingTime)` (negative ages — clock skew — clamp to 0).
- `greenness = max(0, 1 − age/300)` — 0 after 5 min without a newer sample.
- `markerFraction = min(age/900, 1)` — hits 1 at 15 min.
- `showClock = age >= 900`.

## View

Private view struct in `SessionView.swift` — deliberately NOT a new
app-target file: no xcodegen regeneration, no scheme ritual.

- The freshness line replaces the current `Text(ageLabel(r))`: an
  `HStack` of the "updated n min ago" text plus the dotted track filling
  the remaining width to the screen edge.
- Text color: interpolate greyish-green → gray by `greenness`
  (`Color(hue: 0.36, saturation: 0.35 * greenness, brightness: 0.75)`
  or an equivalent blend that lands on the current `.secondary` gray at
  `greenness == 0` — exact constants are the implementer's call, the
  endpoints are not: gray at 0, clearly green-tinted at 1).
- Track: a thin `|` bar at the left end, small dots (fixed count, ~10–14,
  vertically centered on the text line), and a `chevron.left` marker
  offset right by `markerFraction` of the track width; when `showClock`
  is true the chevron is replaced by an SF `clock` symbol pinned at the
  right edge.
- The whole line (and thus the live "n min ago" count) sits in a
  `TimelineView(.periodic(from:by: 15))` so fade and marker move between
  data refreshes.

## NOW-block restructure (`SessionView.swift`)

- Split today's single block-wide button:
  - Row 1 (station name + distance + pin icon) → `Button` opening the
    station picker (unchanged behavior, same label content).
  - Rows 2–3 (wind/gust numbers + compass; freshness line) → `Button`
    that: plays `WKInterfaceDevice.current().play(.click)`, sets a local
    `@State isRefreshing = true` (renders the freshness line at 40 %
    opacity), `await session.refreshTick()`, clears the flag.
- The "No station nearby" fallback row keeps opening the picker,
  unchanged.
- No `SessionController` changes: `refreshTick()` already exists, is
  `@MainActor`, reentry-safe, and provider-agnostic (works in direct
  fallback). Failures surface through the existing offline/error pills.
- Repeated taps just re-run the tick; the server's in-flight dedup
  absorbs the traffic.

## Error handling

- No reading → no freshness line and no refresh button beyond the
  existing "No station nearby" picker entry (as today).
- Fetch failure on tap: dim clears when the tick settles; the existing
  `lastError` pill communicates the failure; the marker keeps aging
  honestly.
- Clock skew (reading timestamp in the future) → age clamps to 0:
  full green, marker at start.

## Testing

- `FreshnessModel` unit tests (exact values): age 0 → `greenness == 1`,
  `markerFraction == 0`, no clock; 150 s → 0.5 / ~0.1667; 300 s →
  greenness 0; 899 s → no clock, fraction < 1; 900 s → clock, fraction 1;
  1800 s → clock, fraction capped at 1; negative age → same as 0.
- Build via `xcodebuild ... watchOS Simulator`; `swift test` all green.
- Hardware checklist: tapping wind numbers or the age line triggers a
  haptic + refresh; station-name row still opens the picker; age text
  turns greyish-green right after a new reading and is gray by ~5 min;
  the `<` marker reaches the edge at ~15 min and becomes a clock symbol;
  the line dims while a tapped refresh is in flight.

## Out of scope

Pull-to-refresh gestures; forecast-block tap-to-refresh; changing the
5-minute auto-refresh cadence; persisting any refresh state; animating
the marker's travel (it repaints on the 15 s timeline, which is enough at
this scale).
