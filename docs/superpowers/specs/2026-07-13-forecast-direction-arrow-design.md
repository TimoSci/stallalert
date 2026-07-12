# NEXT HOUR Forecast-Direction Arrow — Design Spec

**Date:** 2026-07-13
**Status:** Approved design, pre-implementation
**Extends:** 2026-07-11-next-hour-trendline-design.md, 2026-07-09-wind-compass-design.md

## Purpose

Right of the NEXT HOUR mini-graph, show the forecast wind direction for the
same window: the station compass's arrow style (downwind convention, faint
rim circle) without the direction-history shadows, tinted like the NEXT
HOUR numbers and trendline.

## Decisions (made with the user)

| Decision | Choice |
|---|---|
| Arrow style | Small dial: the station compass's faint rim circle + `location.north.fill` arrow, NO history ticks, ~22 pt. |
| Direction value | **Vector mean over the hour**: the same seven 10-min samples the trendline uses, each interpolated vectorially (seam-safe), then vector-averaged. Near-zero resultant → nil → no arrow. |
| Tint | Arrow takes the NEXT HOUR tint (`color(for: nh.minKn)` on the session screen, `.primary` on the start screen); the rim stays neutral `.secondary.opacity(0.3)` like the station dial. |
| Screens | Both (wherever the mini-graph is). |
| Width guard | Folded in from the trendline review's queued Minor: `.lineLimit(1).minimumScaleFactor(0.8)` on the NEXT HOUR numbers Text, both screens. |

## Package changes (StallAlertKit)

### ForecastEngine
- `NextHourView` gains `dirDeg: Double?` — appended LAST, `= nil` init
  default (existing call sites/tests compile unchanged).
- `nextHour(from:at:)` computes it alongside the existing sampling: at each
  of the 7 sample times, interpolate direction between the bracketing
  steps VECTORIALLY (lerp the `(sin, cos)` unit-vector components by the
  same time fraction the scalar interpolation uses, `atan2` back; exact
  step hit → that step's direction). Sum the 7 unit vectors; if the
  resultant magnitude < 1.0e-9, `dirDeg = nil`; else `atan2` → degrees
  normalized to [0, 360).
- The existing scalar `interpolate` and all current fields/semantics are
  unchanged.

### CompassModel
- New: `public static func downwindAngle(fromDeg deg: Double) -> Double` —
  `(deg + 180)` normalized to [0, 360). The existing `render` switches to
  calling it for the arrow and ticks (behavioral no-op — existing
  CompassModel tests must pass unchanged, proving the extraction).

## View (internal struct in `watch/App/Views/StartView.swift`)

```swift
struct ForecastArrowView: View {
    let dirDeg: Double
    let tint: Color
    var size: CGFloat = 22
    // ZStack: Circle().stroke(.secondary.opacity(0.3), lineWidth: 1)
    //  + Image(systemName: "location.north.fill")
    //      .font(.system(size: size * 0.45))
    //      .rotationEffect(.degrees(CompassModel.downwindAngle(fromDeg: dirDeg)))
    //      .foregroundStyle(tint)
    //  .frame(width: size, height: size)
}
```

- Placement: appended to the existing NEXT HOUR `HStack(spacing: 6)` on
  both screens, right of `TrendlineView`, wrapped `if let d = nh.dirDeg`.
- Numbers Text on both screens gains `.lineLimit(1).minimumScaleFactor(0.8)`.
- No new app-target file (lives beside `TrendlineView` in StartView.swift);
  no xcodegen.

## Error handling

- No forecast → block absent (unchanged).
- `dirDeg` nil (cancelling directions, or stale in-memory default) →
  numbers + graph render without the arrow.
- Station compass behavior untouched (shared helper is a pure extraction).

## Testing

- ForecastEngine (extend existing fixture tests + new synthetic):
  constant 90° across steps → `dirDeg == 90`; seam: steps at 350° and 10°
  bracketing the window → mean 0° (± 0.1); opposing directions (0° and
  180° in equal measure) → nil; existing count/last/min assertions
  untouched.
- CompassModel: `downwindAngle` pins 350→170, 90→270, 180→0, 0→180;
  ALL existing CompassModel tests pass unchanged (extraction proof).
- Build via `xcodebuild ... watchOS Simulator`; `swift test` green.
- Hardware checklist: arrow right of the mini-graph on both screens,
  matches windguru.cz's forecast direction for the spot (downwind
  convention, same as the station arrow's convention); tinted like the
  numbers; numbers never wrap to two lines.

## Out of scope

Direction trend/shadows for the forecast; per-sample direction display;
onshore/offshore classification; moving the station compass.
