# Dual-Chevron Freshness Line Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The freshness text becomes "measured x min ago" (slightly greener when fresh), and the dotted track carries two traveling chevrons — green for time-since-last-successful-fetch, blue for the station sample's age.

**Architecture:** Spec 2026-07-12-dual-chevron-freshness-design.md. `FreshnessModel` is untouched — the view calls `render` twice (measured clock: text/fade/blue chevron/clock symbol; update clock: green chevron position only). `SessionController` gains one observable `lastSuccessfulFetch: Date?` stamped on fetch success and nilled on teardown.

**Tech Stack:** existing — SwiftUI watch app; StallAlertKit unchanged. No new dependencies, no server changes.

## Global Constraints

- `FreshnessModel`/package: ZERO changes; suite stays at 89 tests, 0 failures, zero warnings.
- Text: `"measured \(minutes) min ago"`; color `Color(hue: 0.36, saturation: 0.5 * greenness, brightness: 0.75)` (coefficient 0.35 → 0.5; hue/brightness unchanged).
- Chevrons: same glyph (`chevron.left`, size 8 semibold) — update in `.green` at the update render's fraction, measured in `.blue`; green drawn UNDER blue (earlier in the ZStack); green omitted when `lastFetchTime == nil`; blue replaced by the `clock` symbol (`.secondary`, unchanged) when `showClock`.
- Track geometry unchanged: marker x = `4 + (w − 8) * fraction`, clock at `w − 5`, TimelineView 15 s cadence.
- **NO new app-target files** → NO xcodegen; scheme guard: `grep -c STALLALERT_ watch/StallAlert.xcodeproj/xcshareddata/xcschemes/StallAlert.xcscheme` prints `4` before AND after.
- Build: `xcodebuild -project watch/StallAlert.xcodeproj -scheme StallAlert -destination 'generic/platform=watchOS Simulator' build` → BUILD SUCCEEDED.
- Branch: `dual-chevron-freshness` off `main`.

---

### Task 1: lastSuccessfulFetch + dual-chevron view

**Files:**
- Modify: `watch/App/SessionController.swift` (one property + one stamp + one reset)
- Modify: `watch/App/Views/SessionView.swift:67,113-173` (call site + FreshnessLineView)
- Modify: `docs/hardware-checklist.md` (append section)

**Interfaces:**
- Consumes: `FreshnessModel.render(readingTime:now:) -> FreshnessRender { greenness, markerFraction, showClock }` (existing, unchanged).
- Produces: `SessionController.lastSuccessfulFetch: Date?` (observable); `FreshnessLineView(readingTime: Date, lastFetchTime: Date?)`.

- [ ] **Step 1: SessionController.** Three edits:

(a) Next to the other observable state (near `var servedModelCaption: String?`), add:

```swift
    /// Wall-clock time of the last SUCCESSFUL fetch (any data source), for the
    /// freshness line's green "update" chevron. Distinct from the reading's own
    /// timestamp: a fetch can succeed while the station still serves an old
    /// sample — the gap between the two chevrons is exactly that difference.
    var lastSuccessfulFetch: Date?
```

(b) In `refreshTick()`'s success branch, directly after `conditions = c`, add:

```swift
            lastSuccessfulFetch = Date()
```

(c) In `endSession()`, after `policy = nil`, add:

```swift
        lastSuccessfulFetch = nil
```

- [ ] **Step 2: SessionView call site.** Line 67 changes from

```swift
                                FreshnessLineView(readingTime: r.time)
```

to

```swift
                                FreshnessLineView(readingTime: r.time,
                                                  lastFetchTime: session.lastSuccessfulFetch)
```

- [ ] **Step 3: FreshnessLineView.** Replace the whole struct (SessionView.swift:113-173) with:

```swift
/// "measured n min ago" plus a thin dotted age track with two markers:
/// a green chevron for time since the last SUCCESSFUL fetch (the app's
/// connection health) and a blue chevron for the station sample's age
/// (what the number on screen actually is). A reading is measured before
/// the fetch that delivered it, so blue sits at or right of green except
/// under station clock skew (both clamp identically in the model). The
/// blue marker becomes a clock symbol at 15 min, exactly as before.
/// Text fades greyish-green -> gray over the first 5 min (measured clock).
/// Lives inside SessionView.swift deliberately: adding an app-target file
/// would force an xcodegen regeneration (scheme-wipe ritual).
private struct FreshnessLineView: View {
    let readingTime: Date
    let lastFetchTime: Date?

    var body: some View {
        // 15 s cadence keeps fade/markers/minutes moving between fetches.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let measured = FreshnessModel.render(readingTime: readingTime, now: context.date)
            let update = lastFetchTime.map { FreshnessModel.render(readingTime: $0, now: context.date) }
            let minutes = Int(max(0, context.date.timeIntervalSince(readingTime)) / 60)
            HStack(spacing: 6) {
                Text("measured \(minutes) min ago")
                    .font(.footnote)
                    .foregroundStyle(textColor(greenness: measured.greenness))
                    .fixedSize()
                track(measured: measured, update: update)
            }
        }
    }

    // Endpoints per spec: clearly green-tinted at 1, ~.secondary gray at 0.
    private func textColor(greenness: Double) -> Color {
        Color(hue: 0.36, saturation: 0.5 * greenness, brightness: 0.75)
    }

    private func track(measured: FreshnessRender, update: FreshnessRender?) -> some View {
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
                if let update {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.green)
                        .position(x: 4 + (w - 8) * update.markerFraction, y: geo.size.height / 2)
                }
                if measured.showClock {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .position(x: w - 5, y: geo.size.height / 2)
                } else {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.blue)
                        .position(x: 4 + (w - 8) * measured.markerFraction, y: geo.size.height / 2)
                }
            }
        }
        .frame(height: 12)
    }
}
```

- [ ] **Step 4: Build + suite + scheme guard.**

Run:
```bash
grep -c STALLALERT_ watch/StallAlert.xcodeproj/xcshareddata/xcschemes/StallAlert.xcscheme   # expect 4
xcodebuild -project watch/StallAlert.xcodeproj -scheme StallAlert -destination 'generic/platform=watchOS Simulator' build 2>&1 | tail -3
cd watch/StallAlertKit && swift test 2>&1 | grep -E "Executed .* tests" | tail -1
grep -c STALLALERT_ ../StallAlert.xcodeproj/xcshareddata/xcschemes/StallAlert.xcscheme       # expect 4 (unchanged)
```
Expected: `BUILD SUCCEEDED`; 89 tests, 0 failures (package untouched); both greps print `4`.
Also confirm the package is truly untouched: `git status --porcelain watch/StallAlertKit` prints nothing.

- [ ] **Step 5: Checklist.** Append to `docs/hardware-checklist.md`:

```markdown

## Dual-chevron freshness line (added 2026-07-12)
- [ ] The line under the live wind reads "measured x min ago".
- [ ] Right after a fetch delivers a new sample the text is noticeably
      greener than the old tint, still muted; gray again by ~5 min.
- [ ] Two chevrons on the track: green resets toward the origin on every
      successful fetch (every ~5 min), blue keeps aging with the sample —
      on a slow station they visibly separate.
- [ ] Blue chevron becomes the clock symbol at ~15 min sample age while
      green keeps resetting (healthy connection, stale station).
- [ ] With the server unreachable (offline pill showing), BOTH chevrons
      drift right together.
```

- [ ] **Step 6: Commit**

```bash
git add watch docs && git commit -m "feat(watch): dual measured/update chevrons on the freshness line"
```
