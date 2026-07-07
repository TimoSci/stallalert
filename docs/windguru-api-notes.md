# Windguru API notes (empirical)

Captured 2026-07-06/07 from a logged-in PRO browser session, then verified by
direct replay with `curl`. Windguru's `iapi.php` is undocumented and not a
public/stable API — everything below is inferred from observed behavior, not
from any spec. Re-run `server/scripts/capture_fixtures.sh` and re-verify
against this document if fixtures/parsers start failing; Windguru can change
shape without notice.

All secrets referenced below (`$WG_TOKEN`, `$WG_TOKEN_ALT`, `$WG_COOKIE`,
`$WG_UA`, `$WG_USERNAME`, `$WG_MICRO_PASSWORD`, `$WG_SPOT_ID`,
`$WG_STATION_ID`, `$WG_LAT`, `$WG_LON`) live in the git-ignored
`server/.env.capture` and `server/.env.local`. No secret values appear in
this document.

## General findings

- **`.net` vs `.cz` host**: interchangeable. Verified by replaying the spot
  forecast, custom-lat/lon forecast, and station-list requests against both
  `www.windguru.net` and `www.windguru.cz` with identical results.
- **`X-WG-Token`**: NOT strictly required on any of the four endpoints tested.
  Every endpoint that needed auth accepted the *session cookie* instead; every
  endpoint that didn't need auth worked with the token entirely omitted. We
  did not find a case where the token by itself (no cookie) unlocked a
  PRO-gated endpoint — sending `X-WG-Token: $WG_TOKEN_ALT` alone against the
  custom-forecast endpoint still returned `401 Unauthorized`. Recommendation
  for the adapter: don't rely on the token; use the session cookie for
  PRO-gated calls and skip auth headers entirely for the public ones. Keep
  sending it anyway (cheap, matches browser behavior) but treat the cookie as
  the thing that actually gates access.
- **Session cookie**: when required, the **entire captured cookie string**
  was needed. Two partial subsets were tried and both failed with 401:
  `session` + `login_md5` alone, and `deviceid` + `wgcookie` alone. The full
  jar (`langc`, `deviceid`, `g_state`, `idu`, `login_md5`, `session`,
  `wgcookie`) succeeded. Treat the cookie as an opaque blob to replay whole;
  don't try to derive/construct a minimal subset.
- **`rundef`**: safe to omit. The server always serves the *latest* model
  run regardless. Sending a stale, ~24h-old `rundef` value (from the previous
  day's capture) produced an *identical* response to omitting it entirely —
  Windguru does not error or serve stale data for a stale `rundef`; it simply
  ignores/overrides it and returns the current run's `initdate`/`rundef`.
  Conclusion: the adapter does not need to compute or track `rundef` at all.
- **`id_model`**: `3` (GFS 13 km, global) is available for arbitrary custom
  lat/lon and is what we use as the default model. Two other ids were probed
  for the custom-lat/lon endpoint (a couple of tries, per the discovery
  brief):
  - `id_model=38` → `HTTP 404 {"return":"error","message":"Data not
    available! (outside grid)"}` — this is a regional model whose grid does
    not cover the tested coordinates (Mallorca-area, lat 39.92 lon 3.09), not
    a generic PRO-lock error.
  - `id_model=wg` (literal string, guessing at a "WG blend" id) →
    `HTTP 200 {"return":"error","message":"Data not available!"}` — a
    different error shape than the grid case, suggesting `wg` is simply not
    a recognized model id for this endpoint (no grid to be outside of). We
    did not find a working WG-blend model id for custom coordinates in the
    tries budgeted for this task. Recommendation: use `id_model=3` for the
    adapter's custom-location forecasts; if a WG-blend id is needed later, it
    will require further discovery (possibly only available for saved
    "spot" ids, not arbitrary lat/lon).

## Endpoint 1 — Spot forecast

```
GET https://www.windguru.net/int/iapi.php
    ?q=forecast
    &id_model=3
    &id_spot=$WG_SPOT_ID
    &ai=1
    &WGCACHEABLE=21600
Headers:
  Referer: https://www.windguru.cz/
  User-Agent: $WG_UA
```

- **Minimal working recipe**: `User-Agent` + `Referer` only. No token, no
  cookie needed for this saved-spot forecast.
  - 0 headers → `401 {"return":"error","message":"Unauthorized!"}`
  - + `User-Agent` + `Referer` → `200 OK`, full body
- `rundef`, `cachefix` params seen in the original capture are optional; both
  were dropped in replay with no change in behavior (server just serves the
  latest run either way; `cachefix` appears to be a CDN cache-busting hint,
  not something the backend validates).
- `id_spot` is a numeric id for a saved location (visible in the URL path
  when viewing `windguru.cz/<id_spot>`).

### Response schema (top-level)

```
id_spot, lat, lon, alt, id_model, model            -- location/model echo
wgmodel: { id_model, model, model_name, model_longname,
           lat: [min,max], lon: [min,max],          -- model's global grid bounds
           pro, priority, resolution, resolution_real,
           initdate ("YYYY-MM-DD HH:MM:SS", model init time, UTC),
           initstamp (unix seconds, UTC),
           period (hours between model runs, e.g. 6),
           hr_start, hr_end, hr_step,
           wave, sst, maps, dynamic_updates (booleans),
           rundef (string encoding which run covers which hour ranges —
                   safe to ignore/omit on requests; informational only),
           runs: [ { initdate, oinitdate, run_hr: [start,end],
                     run_hr_steps: [[start,end,step], ...], use_hr: [start,end] }, ... ]
         }
model_alt   -- alternate/backup model id (int)
levels      -- number of vertical levels available (int)
sunrise, sunset  -- "HH:MM" local time strings
md5chk      -- checksum string of the payload (NOT a session/auth token)
default_vars -- { "<id_model>": [list of variable names shown by default] }
coast       -- bool, present for saved coastal spots (absent for custom lat/lon)
fcst        -- object, see below (spot forecast ALSO has a sibling
               `fcst_land` object for a secondary/land-point comparison
               forecast; custom lat/lon forecast does NOT have `fcst_land`)
```

`fcst` (and `fcst_land`) object — **contrary to the task-1-captures.md note
that assumed no `fcst` wrapper**, the hourly arrays and per-forecast metadata
ARE nested one level down inside `fcst`, not at the top level:

```
fcst: {
  initstamp, initdate, init_d, init_dm, init_h, initstr,   -- init time in various formats
  model_name, model_longname, id_model,
  update_last, update_next,        -- "YYYY-MM-DD HH:MM:SS", server refresh bookkeeping
  hours: [0,1,2, ... ]             -- hour offsets from initstamp (0..~78 hourly, then 3-hourly out to ~384)
  vars: [ "GUST","FLHGT","SLP","RH","TMP","TCDC","APCP","APCP1",
          "HCDC","MCDC","LCDC","WINDSPD","WINDDIR","SMERN","SLHGT","PCPT","TMPE" ]
        -- NOTE: this is a metadata/legend list, not an exact key-to-array
           map. Both WINDSPD and WINDDIR *are* present as real keys below,
           but "SMERN" is listed in `vars` with NO corresponding array key
           in `fcst` (a legacy/alias name that doesn't map to a data field).
           Don't derive field names from `vars`; use the array keys directly.
  WINDSPD  -- knots (float), parallel array indexed by `hours`
  GUST     -- knots (float)
  WINDDIR  -- degrees 0-360 (int), meteorological "from" direction
  TMP      -- °C (float), 2m air temp
  TMPE     -- °C (float), "feels like"/effective temp
  SLP      -- hPa (float), sea-level pressure
  RH       -- % (int), relative humidity
  TCDC, HCDC, MCDC, LCDC -- % cloud cover (total/high/mid/low), leading nulls for hours before data starts
  APCP, APCP1, PCPT      -- precipitation (mm), various accumulation windows, leading nulls
  FLHGT, SLHGT           -- freezing level / snow level height (m), leading nulls where not modeled
  img_var_map            -- internal map for map-tile images, ignore
}
```

Fixture: `server/test/fixtures/windguru/forecast.json`.

## Endpoint 2 — Custom lat/lon forecast (PRO feature)

```
GET https://www.windguru.cz/int/iapi.php
    ?q=forecast
    &id_model=3
    &lat=$WG_LAT
    &lon=$WG_LON
    &alt=218
Headers:
  Referer: https://www.windguru.cz/?lat=$WG_LAT&lon=$WG_LON
  User-Agent: $WG_UA
  Cookie: $WG_COOKIE          (the FULL captured cookie string — required)
```

- **Minimal working recipe**: `User-Agent` + `Referer` + the full session
  `Cookie`. Token is not required.
  - 0 headers → `401 Unauthorized!`
  - + `User-Agent`/`Referer` (no auth) → `401 Unauthorized!`
  - + `X-WG-Token: $WG_TOKEN_ALT` (no cookie) → still `401 Unauthorized!`
  - + full `Cookie` (no token) → `200 OK`, full body — **this is the
    PRO gate**: it's the login session, not the token, that unlocks
    arbitrary-coordinate forecasts.
  - Cookie subset `session`+`login_md5` only → `401`
  - Cookie subset `deviceid`+`wgcookie` only → `401`
  - → conclusion: replay the whole cookie string, not a hand-picked subset.
- Confirmed working identically on `www.windguru.net` with the same cookie
  (host-interchangeable, see General findings).
- `rundef` was omitted entirely in replay (see General findings — omitting it
  is safe and returns the latest run).
- Response schema: same `fcst` shape as Endpoint 1 (see above), except
  `id_spot` is `0`, there is no `coast` key, and there is no sibling
  `fcst_land` object (that only appears for saved spots).

Fixture: `server/test/fixtures/windguru/forecast_custom.json`.

## Endpoint 3 — Live station data

```
GET https://www.windguru.cz/int/iapi.php
    ?q=station_data
    &id_station=$WG_STATION_ID
    &from=<ISO8601 UTC, e.g. 2026-07-07T03:28:22.000Z>
    &to=<ISO8601 UTC>
    &avg_minutes=5
    &graph_info=1
Headers:
  Referer: https://www.windguru.cz/$WG_SPOT_ID
  User-Agent: $WG_UA
```

- **Minimal working recipe**: `User-Agent` + `Referer` only — no
  `X-WG-Token`, no cookie needed, for the tested station (id 4048 in the
  original capture; a different, non-public/private station might behave
  differently — if a 401 shows up, add `-H "X-WG-Token: $WG_TOKEN"` and/or
  `-b "$WG_COOKIE"` first, in that order, per the pattern above).
  - 0 headers → `401 Unauthorized!`
  - + `User-Agent`/`Referer` → `200 OK`, full body (token/cookie not needed)
- The original browser capture had an 18h window with `avg_minutes=23`; for
  fixture replay use a short recent window (last ~60 min) with
  `avg_minutes=5` so it stays small and fresh. `from`/`to` must be
  URL-encoded ISO-8601 UTC timestamps with a literal `Z` and milliseconds
  (e.g. `2026-07-07T03%3A28%3A22.000Z`); the server accepts sub-minute
  precision but only actually buckets to `avg_minutes` granularity.

### Response schema

```
datetime      -- "YYYY-MM-DD HH:MM:SS", in the STATION'S LOCAL time
                 (i.e. UTC + tzoffset), not UTC
unixtime      -- unix seconds, UTC (verified: datetime == unixtime + tzoffset)
wind_avg, wind_max, wind_min -- knots (float), per avg_minutes bucket
wind_direction -- degrees 0-360 (int)
temperature   -- °C (float) or null if the station doesn't report it
rh            -- % (int) or null
mslp          -- hPa (float) or null
gustiness     -- unitless index (int) or null, Windguru's own gustiness metric
sunrise, sunset -- "HH:MM" local time strings
startstamp, endstamp -- unix seconds (UTC), actual bucketed window returned
                        (may be padded slightly wider than the requested from/to)
tzoffset      -- seconds to add to UTC to get the station's local time
                 (e.g. 7200 = UTC+2 / CEST)
```

All fields are parallel arrays except `sunrise`/`sunset`/`startstamp`/
`endstamp`/`tzoffset`, which are scalars for the whole response. Some fields
(`temperature`, `rh`, `mslp` in our capture) were entirely `null` across the
window — this particular station apparently only reports wind, not full
weather. Don't assume every station fills every field.

Fixture: `server/test/fixtures/windguru/station_current.json` (captured with
a fresh ~1h window, `avg_minutes=5`, at request time).

## Endpoint 4 — Station list

```
GET https://www.windguru.net/int/iapi.php
    ?q=station_list
    &id_type=0
    &seconds=1800
    &seconds_alive=172800
    &WGCACHEABLE=30
```

- **Minimal working recipe**: no headers at all. `200 OK` with zero
  `User-Agent`/`Referer`/cookie/token.
- `id_type=0` appears to mean "all station types". `seconds=1800` /
  `seconds_alive=172800` look like recency filters (last-reading-age and
  max-staleness windows in seconds) but weren't varied to confirm precisely.
- No lat/lon filter params were found — this is a **global** list; client-side
  filtering by distance is necessary (as done for the fixture, see below).

### Response schema (array of station objects)

```
[
  {
    id_station, uid (external station id string), id_type, id_spot, wg (0/1),
    spotname, name (hardware/model name string),
    lat, lon, alt, timezone (IANA tz string), seconds_alive (age of last reading),
    weather: { wind_avg, wind_min, wind_max, wind_direction, ... }  -- most recent reading
  },
  ...
]
```

### Station-list trimming (applied)

The raw response was **1,156,974 bytes** (3,053 stations) — well over the
~300 KB threshold. Trimmed to stations within 250 km (haversine) of lat
39.92, lon 3.09, plus 20 additional stations chosen via
`random.seed(42); random.sample(far, 20)`, preserving each entry's exact
per-station structure untouched. Result: 43 stations, 22,763 bytes. The full
untrimmed raw file was NOT committed (kept only in a local scratch
directory, outside the repo).

Fixture: `server/test/fixtures/windguru/stations_list.json` (trimmed, as
above).

## Micro API fallback (`micro.windguru.cz`)

```
GET https://micro.windguru.cz/
    ?lat=$WG_LAT
    &lon=$WG_LON
    &u=$WG_USERNAME
    &p=$WG_MICRO_PASSWORD
    &m=gfs
```

Plain HTML page with a `<pre>` text table (not JSON). Findings:

- `m=gfs` → full forecast table (31 hourly rows out to ~24h, then 3-hourly
  out to several days). Columns: `Date` (local "Day D. Hh" format, header
  says `(UTC+0)` even though — note — this looked like UTC-labeled but
  unverified against a second timezone; treat as UTC per the column header),
  `WSPD`/`GUST` (knots, int), `WDIRN` (compass abbreviation),
  `WDEG` (degrees int), `TMP` (°C int), `SLP` (hPa int), `HCLD`/`MCLD`/`LCLD`
  (% cloud, `-` = no data), `APCP`/`APCP1` (mm precip, `-` = none), `RH` (%).
  A header line above the table gives `lat`, `lon`, and `SST` (sea-surface
  temp, °C).
- `m=wg` (WG-blend model, guessed id) → `200 OK` but the response has ONLY
  the `lat/lon/SST` header line and NO forecast table at all — consistent
  with the `iapi.php` finding above that the WG-blend model isn't available
  for this (or perhaps any) custom coordinate.
- `m` omitted entirely → defaults to the same output as `m=gfs`.
- Recommendation: use `m=gfs` explicitly (don't rely on the default) for the
  adapter's micro-API fallback path; this is a *plain-text* fallback, so the
  adapter will need a small line-oriented parser rather than a JSON decoder.

Fixture: `server/test/fixtures/windguru/micro_forecast.txt` (captured with
`m=gfs`).

## Sanitization

All five fixture files were grepped for the values of `idu`, `login_md5`,
`session`, `deviceid`, `wgcookie`, `g_state`, `$WG_TOKEN`, `$WG_TOKEN_ALT`,
and `$WG_USERNAME` (loaded from the git-ignored env files, never printed) —
**no matches were found**. A further scan for `@` (email addresses) and for
JSON keys named `email`/`user`/`login`/`username`/`password`/`idu` also found
nothing. The forecast/station/micro payloads are pure weather data; no
session or account-identifying material leaked into any fixture. No
redaction was necessary.

## Open risks for the adapter task

- **WG-blend model unavailable for custom coordinates** (or at least not
  found in this task's budget of tries) — the adapter should default to
  `id_model=3` (GFS 13 km) for arbitrary lat/lon and treat any WG-blend
  support as a stretch goal requiring further discovery.
- **Station auth is station-dependent**: station 4048 needed zero auth
  headers; a private/unshared station may require the cookie or token. The
  adapter should be prepared to retry with `X-WG-Token` and then the full
  cookie if a `station_data` call returns 401.
- **`rundef`/`cachefix` are safe to drop**, but this was verified with only
  one stale value on one endpoint (spot forecast) and one omission test on
  the custom-forecast endpoint; if Windguru ever changes this behavior,
  omitting `rundef` might start returning an older/cached run instead of the
  latest — worth a smoke-test assertion in the adapter's test suite
  (`initstamp` should always be within one model-cycle-period of "now").
- **`iapi.php` is unversioned and undocumented**; no rate-limit or ToS
  guidance was found. Keep client-side rate limiting conservative (this
  capture session used ~2.5s between requests and stayed well under 30
  total calls).
- **Micro API's `(UTC+0)` column header is stated but not independently
  cross-checked** against a second known-timezone location; treat as UTC
  per the header text, flag if forecast/actuals disagree with the JSON
  endpoints once both are wired up.

## Open risk: session-cookie acquisition (resolved, Task 5 — "no" outcome)

**No automated login flow was found.** `WG_COOKIE` remains a fully opaque, manually
-copy-pasted browser session string with unknown expiry and no discovered renewal
process. The custom lat/lon (PRO) forecast endpoint — the primary data source — depends
entirely on it. This is a documented, accepted operational limitation, not an oversight:
the adapter (`Stallalert.Windguru.HTTPAdapter`) reads `WG_COOKIE` from the environment on
every call and maps 401/403 to `{:error, :auth_required}` (cookie absent) or
`{:error, :cookie_expired}` (cookie present but rejected) so callers/operators can tell
the two failure modes apart. `WG_COOKIE` must be refreshed manually from a logged-in
browser session when it expires (see `docs/deploy.md`).

### Probe log (Task 5, ~11 requests, 2.5-3s spacing, budget ~12)

All probes below used credentials sourced from the git-ignored `server/.env.local`
(`WG_USERNAME`/`WG_PASSWORD`), never printed or logged. No captcha, lockout, or
account-warning signal was observed at any point — probing stopped because the budget
was reached and every avenue plausibly worth trying inside it had been exhausted, not
because of a stop signal.

1. `GET https://www.windguru.cz/` (homepage, with a browser `User-Agent`) → `200`.
   Inspected the HTML for a login form/action: no `<form>` for login exists in the
   static markup. The only login affordance is `<a href="javascript:WG.user.loginWindow();">`
   — a client-side JS modal, not a plain HTML form with a discoverable `action=`.
   A `data-guide-src="login.php"` attribute turned out to be for an unrelated onboarding
   "tour guide" overlay, not a real endpoint.
2. `GET https://www.windguru.net/wg/js/dist/709/main-wg.js` → `200`. Grepped the bundle
   for `iapi` / `login` substrings: zero matches (this bundle is a thin loader).
3. `GET https://www.windguru.net/wg/js/prod/libs-wg.<hash>.js` → `200` (294 KB). Grepped
   for `iapi` / `*login*` substrings: zero matches — the login flow's JS isn't in this
   bundle either (likely a lazy-loaded chunk not reachable via static grep within budget).
4. `POST https://www.windguru.cz/int/iapi.php` with body `q=user_login&login=...&password=...`
   → `400 {"return":"error","message":"Missing query"}`.
5. `POST .../iapi.php` with body `q=login&username=...&password=...` → `400 "Missing query"`.
6. `POST .../iapi.php` with body `q=user_login&username=...&password=...` → `400 "Missing query"`.
7. `POST .../iapi.php?q=user_login` (q in the URL query string instead, `login`/`password`
   in the POST body) → `400 "Missing query"`.
8. `POST .../iapi.php?q=user_login` (q in URL, `username`/`password` in body) →
   `400 "Missing query"`.
9. `GET https://www.windguru.cz/int/iapi.php?q=user_login` (no credentials, just to see
   whether `q` was even recognized outside a POST) → `401 {"return":"error","message":"Not enough permission"}`.
10. `GET .../iapi.php?q=totallybogus12345` (a deliberately invalid `q`, for comparison) →
    also `401 "Not enough permission"` — identical to #9. This shows `q=user_login` isn't
    being specially recognized as a login endpoint via GET either; unrecognized/gated `q`
    values just fall through to a generic permission error.
11. `POST .../iapi.php?q=user_login` with a JSON body (`Content-Type: application/json`,
    `{"login":...,"password":...}`) instead of form-encoding → `400 "Missing query"` again.

**Conclusion**: every POST to `iapi.php` (any `q`, any field-name guess, any body
encoding) returned the same generic `400 "Missing query"`, while GET requests reached
the query dispatcher fine (`401 "Not enough permission"` for both a login-shaped `q`
and a nonsense one). This is consistent with `iapi.php` only accepting GET for query
dispatch — the real login mechanism is client-side JS (`WG.user.loginWindow()`) calling
some endpoint not found in the two JS bundles fetched within budget, or requiring
request shaping (headers, CSRF token, XHR-specific markers) not reproduced by plain
curl. No working login flow was found; no captcha/lockout was triggered.

**Recommendation for future work**: if automated cookie refresh becomes worth pursuing,
the next step is capturing the actual login XHR from a real browser session (Task 1's
capture method) rather than guessing field names blind — the JS-driven login modal
almost certainly posts to a specific, non-obvious endpoint/shape that black-box guessing
under a small budget didn't surface.
