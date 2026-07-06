# StallAlert — Design Spec

**Date:** 2026-07-06
**Status:** Approved design, pre-implementation

## Purpose

A standalone Apple Watch app for kitesurfing that shows the Windguru wind
forecast (next hour) and live measurements for the rider's GPS position, and
raises a loud haptic + audible alarm when the wind is predicted or measured to
drop below a configurable threshold — so the rider can head in before the kite
stalls.

The user has a Windguru PRO subscription and a cellular Apple Watch.

## Key decisions (made with the user)

| Decision | Choice |
|---|---|
| Connectivity | Cellular watch; live fetching from the water |
| "Min/max next hour" | Base wind = min, gusts = max, **plus** trend into the next hour (e.g. "14–22 kn ↓ dropping to ~11") |
| Current measurements | Nearest Windguru live station to GPS position, with distance shown |
| Alert trigger | Forecast next-hour min **or** live station reading below threshold; fires once per event, re-arms after recovery (+2 kn hysteresis) |
| Runtime model | HealthKit workout session (water sports) keeps the app alive, GPS hot, and guarantees haptics |
| Architecture | A: watch talks to Windguru directly; no proxy, no iPhone app (client isolated behind a protocol so a proxy can be added later) |

## Platform

- watchOS 11+, SwiftUI, Swift. Single Xcode project, watch-only app target.
- No iPhone UI in v1; settings live on the watch.

## Components

Each unit has one purpose, a defined interface, and is testable in isolation.

### 1. `WindguruClient` (protocol + `LiveWindguruClient`)
All Windguru HTTP access. Nothing else in the app touches the network.

- `forecast(lat:lon:) async throws -> ForecastTimeline` — normalized hourly
  timeline of wind speed, gusts, direction. Primary source: the widget JSON
  endpoint (`www.windguru.cz/int/iapi.php?q=forecast`) with PRO login, WG
  model. Fallback: PRO micro API (`micro.windguru.cz`, lat/lon + username +
  secondary password, text format).
- `nearestStations(lat:lon:) async throws -> [Station]` and
  `currentReading(stationID:) async throws -> StationReading` — stations JSON
  API for live wind.
- Credentials in Keychain. Parse failures throw a typed `dataSourceError`,
  never crash or return silent zeros.

**Risk (top of list):** these endpoints are unofficial. First implementation
task is to verify real response shapes with the user's PRO account, using
captured payloads as test fixtures. If unusable, fall back to micro API or
revisit the proxy approach behind the same protocol.

### 2. `ForecastEngine` (pure logic)
Input: `ForecastTimeline` + current time. Output: `NextHourView` — base wind
(min), gusts (max), trend direction and projected base wind, interpolating
across the next one or two model steps (handles both 1 h and 3 h step models).

### 3. `AlertPolicy` (pure logic)
State machine: `armed → fired → silencedUntilRecovery → armed`.
Input each tick: forecast next-hour min, latest station reading (+ age),
threshold. Fires when either value < threshold. Re-arms only after both
recover above threshold + 2 kn hysteresis. Stale station readings (> 20 min)
are excluded from evaluation; forecast-only evaluation continues offline.
Alert events carry their cause: `.predicted` or `.measured`.

### 4. `SessionController`
Wraps `HKWorkoutSession` (water sports activity type) + CoreLocation.
Owns the refresh loop: forecast every 15 min, station reading every 5 min,
re-resolve nearest station when position moves > 2 km. Feeds `ForecastEngine`
and `AlertPolicy`; exposes observable state to the UI. Enables Water Lock on
session start.

### 5. `AlertPresenter`
Plays the alarm: strongest available haptic pattern + audible tone
(`AVAudioSession` route to watch speaker), repeated 3 times over ~30 s or
until acknowledged by tap. Also drives the full-screen red alert view.
Includes a "test alarm" action used from settings.

### 6. SwiftUI views
- **Start screen:** next-hour forecast at GPS position, nearest station live
  reading, threshold (Digital Crown adjustable), Start Session button.
- **Session screen:** glanceable in ~1 s —
  forecast range + trend ("14–22 kn ↓ dropping to ~11"), live station block
  (wind, gusts, direction, station name, distance, reading age), armed
  threshold indicator. Numbers tinted green / amber (within 3 kn of
  threshold) / red (below).
- **Alert screen:** full-screen red, cause-labelled ("predicted" vs
  "measured now"), tap to acknowledge.
- **Settings:** threshold (default 12 kn), units (default knots), Windguru
  credentials, test alarm.

## Data flow

```
GPS (CoreLocation)
   │
SessionController ──▶ WindguruClient ──▶ ForecastEngine ──▶ UI
   │                        │                  │
   │                        └── station ───────┤
   │                                           ▼
   └──────────────────────────────────▶ AlertPolicy ──▶ AlertPresenter
```

## Error handling

- **Offline mid-session:** keep last-fetched forecast (still valid), badge the
  live block "no signal", retry with exponential backoff. Predicted-drop
  alerts keep working from cache.
- **Endpoint broken / parse failure:** explicit "data source error" state.
- **Auth failure:** explicit "check Windguru login" state.
- **No station within 30 km:** live block shows "no station nearby";
  forecast-only alerting.
- **Stale data:** station reading > 20 min old grays out with age warning —
  never presented as fresh.
- **GPS unavailable:** last known position, badged.
- **Battery:** refresh cadence is the tuning knob; target = 3 h session with
  comfortable margin.

## Testing

- Unit tests for `ForecastEngine` and `AlertPolicy` (pure): threshold
  crossings, hysteresis re-arm, trend interpolation (1 h and 3 h steps),
  timezone/DST boundaries, stale-data exclusion.
- `WindguruClient` tested against recorded real fixture payloads; one opt-in
  live integration test using real credentials.
- Manual on-hardware verification for haptics, audio, Water Lock, cellular,
  and workout-session lifecycle (simulator cannot cover these).

## Out of scope (v1)

Complications, iPhone companion app, wind-direction alerts, multiple
spots/favorites, session history/stats beyond automatic HealthKit recording.
