# Dual-Chevron Freshness Line — Design Spec

**Date:** 2026-07-12
**Status:** Approved design, pre-implementation
**Extends:** 2026-07-10-freshness-indicator-design.md

## Purpose

The freshness line currently tells one story (age of the displayed station
sample). Split it into two: the text becomes "measured x min ago" (which is
what that timestamp actually is), and the dotted track carries TWO traveling
chevrons — a green **update** chevron (time since the app last successfully
fetched data) and a blue **measured** chevron (age of the station sample,
today's behavior). The gap between them is the new signal: green near the
origin with blue far right = app healthy but station slow; both drifting
right together = connection dead. The fresh-end text color also gets
slightly greener (still greyish-green).

## Decisions (made with the user)

| Decision | Choice |
|---|---|
| Update-chevron reset | **Any successful fetch** (even if the station sample is unchanged). |
| Edge behavior | Blue keeps today's behavior — becomes the SF `clock` symbol at 15 min (same neutral `.secondary` gray as today; it is a warning glyph, not a chevron). Green just parks at the edge. |
| Text fade clock | **Measured** (unchanged): text, fade, and wording tell one story. |
| Chevron colors | Update = `.green`, measured = `.blue`; blue draws on top when they overlap (overlap = everything fresh). |

## Model — NO CHANGES

`FreshnessModel` stays byte-identical (all existing tests untouched). The
view calls `render` twice:

- `render(readingTime: reading.time, now:)` → text minutes, `greenness`
  (text color), blue chevron `markerFraction`, `showClock`.
- `render(readingTime: lastSuccessfulFetch, now:)` → green chevron
  `markerFraction` only (its `greenness`/`showClock` are ignored).

Invariant (documented in a code comment, not enforced): a reading is
measured before the fetch that delivered it, so blue's fraction ≥ green's
except under station clock skew (both clamp identically).

## SessionController

- New observable property: `var lastSuccessfulFetch: Date?` (initially nil).
- Stamped `Date()` in `refreshTick()`'s success branch (same block that
  assigns `conditions`).
- Reset to nil in `endSession()`'s teardown (alongside the existing state
  clearing) so the next session starts without a green chevron until its
  first successful fetch.

## View (`FreshnessLineView` in `SessionView.swift`)

- Text: `"measured \(minutes) min ago"` — minutes computation unchanged
  (measured clock).
- Text color: `Color(hue: 0.36, saturation: 0.5 * greenness,
  brightness: 0.75)` — coefficient raised from 0.35 to 0.5; hue and
  brightness unchanged.
- View signature gains `let lastFetchTime: Date?`; SessionView passes
  `session.lastSuccessfulFetch`.
- Track (unchanged geometry: `|` origin bar, 12 dots, marker x =
  `4 + (w − 8) * fraction`, clock pinned at `w − 5`):
  - Measured chevron: today's `chevron.left`, now `.foregroundStyle(.blue)`;
    replaced by the `clock` symbol (`.secondary`, as today) when
    `showClock`.
  - Update chevron: same glyph/size in `.green` at the update render's
    fraction; drawn BEFORE (under) the measured chevron in the ZStack;
    omitted entirely when `lastFetchTime` is nil.
- Everything else (TimelineView 15 s cadence, 40 % in-flight dim wrapping
  the whole line, tap-to-refresh button structure) unchanged.

## Error handling

- Failed fetches: neither timestamp advances — both chevrons age honestly;
  the offline pill continues to carry the error text.
- No reading → no freshness line (unchanged); `lastFetchTime` nil → blue
  only.
- Clock skew: both clocks clamp negative ages to 0 via the existing model.

## Testing

- No package changes → no new unit tests; existing suite must stay green
  (89 tests).
- Build via `xcodebuild ... watchOS Simulator`.
- Hardware checklist: text reads "measured x min ago"; fresh text is
  visibly greener than before but still muted; two chevrons visible after
  a quiet spell (green resets on each 5-min auto-fetch, blue keeps aging
  on a slow station); blue becomes the clock at 15 min while green keeps
  resetting; green parks at the edge only when fetches are failing (offline
  pill showing).

## Out of scope

Alerting on stale data; labeling the chevrons; showing fetch errors on the
track; changing the 15-min/5-min constants; the start screen (no freshness
line there).
