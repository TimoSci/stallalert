# StallAlert — Design Spec

**Date:** 2026-07-06
**Status:** Approved design, pre-implementation

## Purpose

An Apple Watch app for kitesurfing that shows the Windguru wind forecast
(next hour) and live measurements for the rider's GPS position, and raises a
loud haptic + audible alarm when the wind is predicted or measured to drop
below a configurable threshold — so the rider can head in before the kite
stalls.

The watch gets its data from a **self-hosted intermediary service** (Elixir,
running on the user's fixed-IP host behind a domain name). Only when that
service is unreachable does the watch fall back to fetching from Windguru
directly.

The user has a Windguru PRO subscription and a cellular Apple Watch.

## Key decisions (made with the user)

| Decision | Choice |
|---|---|
| Connectivity | Cellular watch; live fetching from the water |
| "Min/max next hour" | Base wind = min, gusts = max, **plus** trend into the next hour (e.g. "14–22 kn ↓ dropping to ~11") |
| Current measurements | Nearest Windguru live station to GPS position, with distance shown |
| Alert trigger | Forecast next-hour min **or** live station reading below threshold; fires once per event, re-arms after recovery (+2 kn hysteresis) |
| Runtime model | HealthKit workout session (water sports) keeps the app alive, GPS hot, and guarantees haptics |
| Architecture | Self-hosted intermediary service is the primary data source; watch falls back to direct Windguru access only when the service is down. No iPhone app. |
| Service stack | Elixir (Plug + Bandit, Req HTTP client), GenServer poller with ETS cache, shipped as a mix release in Docker on the user's fixed-IP host |
| Service TLS | Domain name pointed at the fixed IP + auto-renewed Let's Encrypt certificate (keeps watchOS ATS happy) |

## Platform & repo layout

- Watch app: watchOS 11+, SwiftUI, Swift. Single Xcode project, watch-only
  app target. No iPhone UI in v1; settings live on the watch.
- Intermediary service: Elixir ~> 1.17, Plug + Bandit, Req for HTTP, Jason
  for JSON. Packaged as a mix release in a Docker container, deployed on the
  user's fixed-IP host, reached via a domain name with an auto-renewed
  Let's Encrypt certificate.
- One repo, two top-level directories: `watch/` (Xcode project) and
  `server/` (Elixir app).

## Components

Each unit has one purpose, a defined interface, and is testable in isolation.

### 0. Intermediary service (`server/`, Elixir)

The primary data source for the watch. Logs into Windguru, fetches and
normalizes forecast + nearest-station data, and serves one small JSON payload.

- **HTTP API** (Plug + Bandit, HTTPS via the host's reverse proxy or directly
  terminated in the app):
  - `GET /v1/conditions?lat=..&lon=..` → `{forecast: ForecastTimeline,
    station: {info, reading} | null, generated_at}` — everything the watch
    needs in one round-trip (small payload, good over cellular).
  - `GET /v1/health` → 200 when the service can serve data.
  - Auth: static bearer token shared with the watch app (set in server config,
    stored in the watch Keychain).
- **Poller (GenServer):** fetches Windguru on a schedule (forecast every
  15 min, station readings every 5 min) for the most recently requested
  position(s), caches normalized results in ETS. Watch requests are served
  from cache, so a Windguru hiccup never blocks a watch request. A cache
  entry older than its refresh interval + grace is served with a `stale: true`
  flag rather than dropped.
- **Windguru adapter:** the only module that knows Windguru's formats.
  Primary: widget JSON endpoint (`www.windguru.cz/int/iapi.php?q=forecast`)
  with PRO login, WG model; stations JSON API for live readings. Fallback:
  PRO micro API (lat/lon + username + secondary password, text format).
  Windguru credentials live in the server's runtime config (env vars) — not
  on the watch, except for the watch's own direct-fallback mode (below).
  A parse crash is isolated by the supervision tree; the service keeps
  serving the last good cached payload.

**Risk (top of list):** the Windguru endpoints are unofficial. First
implementation task is to verify real response shapes with the user's PRO
account, using captured payloads as test fixtures. The service is the place
where format changes get fixed — a server redeploy, no app-store cycle.

### 1. Watch data layer: `WindDataProvider` protocol, two implementations

Nothing else in the watch app touches the network. Both implementations
return the same normalized types (`ForecastTimeline`, `Station`,
`StationReading`).

- **`ServiceClient` (primary):** calls the self-hosted service's
  `/v1/conditions` with the bearer token. One request per refresh tick.
- **`DirectWindguruClient` (fallback):** talks to Windguru's endpoints
  directly (same adapter logic as the server, in Swift; micro API as its own
  fallback). Uses Windguru credentials stored in the watch Keychain.
- **`FailoverProvider`:** wraps both. Tries the service (5 s timeout); on
  timeout, connection error, or 5xx, marks the service down, serves the tick
  via `DirectWindguruClient`, and surfaces the active source to the UI.
  While down, it re-probes `/v1/health` on each tick and switches back as
  soon as the service responds. Auth errors (401) are surfaced as
  configuration errors, not treated as "down".
- Parse failures anywhere throw a typed `dataSourceError`, never crash or
  return silent zeros.

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
Owns the refresh loop: one `WindDataProvider` fetch every 5 min (cheap —
the service answers from its cache; in direct-fallback mode the provider
fetches the forecast at most every 15 min and the station every 5 min to
limit Windguru traffic). Re-resolves the nearest station when position moves
> 2 km. Feeds `ForecastEngine` and `AlertPolicy`; exposes observable state,
including the active data source (service / direct / cached-offline), to the
UI. Enables Water Lock on session start.

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
- **Settings:** threshold (default 12 kn), units (default knots), service
  URL + bearer token, Windguru credentials (for direct fallback), test alarm.
- The session screen shows a small data-source badge when not on the normal
  path: "direct" when the service is down, "offline" when serving cached data.

## Data flow

```
                         ┌── primary ──▶ self-hosted service ──▶ Windguru
GPS (CoreLocation)       │                 (Elixir, cache)
   │                     │
SessionController ──▶ FailoverProvider ──▶ ForecastEngine ──▶ UI
   │                     │                       │
   │                     └── fallback ──▶ Windguru (direct)
   │                                             ▼
   └────────────────────────────────────▶ AlertPolicy ──▶ AlertPresenter
```

## Error handling

- **Service unreachable (timeout 5 s, connection error, or 5xx):**
  `FailoverProvider` switches to direct Windguru access for that tick and
  shows a "direct" badge; it re-probes `/v1/health` each tick and switches
  back automatically. A service 401 is a config error ("check service
  token"), not failover.
- **Fully offline mid-session (service AND direct unreachable):** keep
  last-fetched forecast (still valid — it's a forecast), badge the live block
  "no signal", retry with exponential backoff. Predicted-drop alerts keep
  working from cache.
- **Windguru broken (format change / outage):** the service keeps serving its
  last good cache with `stale: true`; the watch shows data age honestly.
  Parse failures on either side surface as an explicit "data source error"
  state.
- **Auth failure against Windguru:** explicit "check Windguru login" state
  (on the server: logged + health stays OK while cache is fresh).
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
- Server (ExUnit): Windguru adapter tested against recorded real fixture
  payloads; poller/cache behavior (staleness flags, crash recovery); one
  opt-in live integration test using real credentials.
- Watch: `ServiceClient` and `DirectWindguruClient` tested against fixtures;
  `FailoverProvider` tested for down-detection, per-tick recovery probing,
  and 401-vs-down distinction (with a stubbed service).
- Manual on-hardware verification for haptics, audio, Water Lock, cellular,
  and workout-session lifecycle (simulator cannot cover these). End-to-end
  check includes killing the service mid-session and watching the app fail
  over and recover.

## Out of scope (v1)

Complications, iPhone companion app, wind-direction alerts, multiple
spots/favorites, session history/stats beyond automatic HealthKit recording.
