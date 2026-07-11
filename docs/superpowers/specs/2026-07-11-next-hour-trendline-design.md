# NEXT HOUR Trendline — Design Spec

**Date:** 2026-07-11
**Status:** Approved design, pre-implementation
**Extends:** 2026-07-06-stallalert-design.md

## Purpose

The trend arrow next to the NEXT HOUR forecast (`↑ → ↓` from
`trendSymbol`) is confusable with a wind-direction arrow — the compass
right below it genuinely IS one. Replace it with a mini trendline
("sparkline") of the next hour's base wind, drawn against a faint alert
threshold line, so trend reads as a shape and stall proximity is visible
at a glance.

## Decisions (made with the user)

| Decision | Choice |
|---|---|
| Span | **Next hour** — the graph draws the same data as the numbers beside it (the engine's existing 10-min samples), not a longer horizon. |
| Content | **Base wind line + faint threshold line** (dashed red at the alert threshold). No gust band. |
| Scope | **Both screens** (SessionView and StartView); `trendSymbol` deleted entirely. |

## Data (`ForecastEngine`, StallAlertKit)

`NextHourView` gains the samples the engine already computes and throws
away:

```swift
public struct NextHourView: Equatable, Sendable {
    public let minKn: Double
    public let maxKn: Double
    public let trend: Trend
    public let projectedBaseKn: Double
    public let samplesKn: [Double]   // NEW — appended LAST
    public init(minKn: Double, maxKn: Double, trend: Trend,
                projectedBaseKn: Double, samplesKn: [Double] = [])
}
```

`nextHour(from:at:)` passes its `bases` array (7 entries: 10-min samples
across [now, now+1h], first = base now, last = `projectedBaseKn`).
The `Trend` enum and all existing fields/semantics are unchanged (the
"dropping to ~X" caption still consumes `trend`).

## Math (`TrendlineModel`, StallAlertKit, pure)

```swift
public struct TrendlineRender: Equatable, Sendable {
    public let ys: [Double]       // normalized [0, 1], 0 = range bottom; one per sample
    public let thresholdY: Double // same space
    public init(ys: [Double], thresholdY: Double)
}
public enum TrendlineModel {
    /// nil when samplesKn.count < 2 (nothing to draw).
    public static func render(samplesKn: [Double], thresholdKn: Double) -> TrendlineRender?
}
```

- Range: `lo = min(samples.min, threshold)`, `hi = max(samples.max,
  threshold)` — the threshold line is always in frame.
- Minimum span: if `hi − lo < 4` (kn), expand symmetrically around the
  midpoint to exactly 4 — flat forecasts draw flat instead of amplifying
  sub-knot noise.
- `y(v) = (v − lo) / (hi − lo)`; `ys` maps the samples in order,
  `thresholdY` maps the threshold. All outputs in [0, 1].

## View (internal struct in `watch/App/Views/StartView.swift`)

`TrendlineView` replaces the file-level `trendSymbol` helper in the same
file (shared by both screens; no new app-target file → no xcodegen, no
scheme ritual):

- ~36 × 14 pt. A `Path` connecting the sample points, equal x-spacing,
  y flipped for screen coordinates (normalized 1 = top). Stroke ~1.5 pt,
  rounded joins, colored by the SAME `color(for: nh.minKn)`
  threshold-tinting the adjacent numbers use (green/orange/red).
- Threshold: a horizontal dashed line (dash ~2/2, ~1 pt) at
  `thresholdY`, `.red.opacity(0.4)`.
- Renders from `TrendlineModel.render(samplesKn: nh.samplesKn,
  thresholdKn: session.settings.thresholdKn)`; if it returns nil, the
  view renders nothing (numbers stand alone).
- Placement (both screens): `Text("\(min)–\(max) kn \(trendSymbol(...))")`
  becomes `HStack(spacing: 6) { Text("\(min)–\(max) kn"); TrendlineView(...) }`
  with the existing font/color modifiers staying on the Text. StartView
  reads the threshold from its own environment's settings, same as
  SessionView.
- `trendSymbol(_:)` is deleted; no other caller exists (verified: only
  StartView.swift:11 and SessionView.swift:16).

## Error handling

- No forecast → NEXT HOUR block absent (unchanged).
- `samplesKn` empty (old in-memory state, defensive) → `render` nil →
  no graph, numbers unchanged.
- Threshold edits in Settings flow through on the next view render (the
  views read `settings.thresholdKn` live; no caching).

## Testing

- `TrendlineModel` unit tests (exact values):
  - samples [10, 12] threshold 8 → lo 8, hi 12, ys [0.5, 1.0],
    thresholdY 0.0;
  - threshold above all samples in frame: samples [10, 12] threshold 15 →
    lo 10, hi 15, thresholdY 1.0;
  - min-span expansion: samples [10, 11] threshold 10.5 → natural span 1
    → range 8.5…12.5, ys [0.375, 0.625], thresholdY 0.5;
  - count < 2 → nil (empty and single-sample);
  - samples spanning the threshold: samples [6, 12] threshold 9 →
    thresholdY 0.5.
- `ForecastEngine` tests extend the existing fixture-based test:
  `samplesKn.count == 7`, `samplesKn.first == baseNow` (== existing
  expectation for the interpolated now-value), `samplesKn.last ==
  projectedBaseKn`.
- Build via `xcodebuild ... watchOS Simulator`; `swift test` green.
- Hardware checklist: arrow gone on BOTH screens; graph slopes down and
  approaches the red dashes when the forecast drops toward the
  threshold; flat forecast draws a near-flat line; graph color matches
  the numbers' color.

## Out of scope

Gust band; multi-hour horizon; axis labels/ticks; animating the line;
plotting live readings; threshold line on the compass.
