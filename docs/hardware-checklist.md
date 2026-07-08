# StallAlert hardware verification

Deploy via Xcode to the paired watch (open `watch/StallAlert.xcodeproj` after
`xcodegen generate`, select your watch as run destination) or via TestFlight.
Server is live at https://stallalert.com (see docs/deploy.md; the API token is
in the git-ignored `server/.env.deploy` on the workstation).

Record results inline (✅/❌ + notes). Items marked (review) came out of code
review and verify specific decisions.

## Setup & configuration
- [ ] Settings: enter service URL (`https://stallalert.com`), API token,
      Windguru username + SECONDARY (micro) password; Save; force-quit and
      relaunch the app; values persist (Keychain round-trip on device).
- [ ] (review) Keychain under Water Lock: with a session running and Water
      Lock engaged, wait past one 5-min refresh tick — data still updates
      (secrets are stored AfterFirstUnlockThisDeviceOnly; a failure here
      means credential reads are blocked mid-session).
- [ ] Test alarm (Settings): haptics clearly felt on wrist; tone clearly
      audible outdoors at arm's length.

## Session lifecycle
- [ ] First-ever session start: HealthKit permission prompt appears; GRANT →
      session starts, Water Lock engages, GPS lock < 1 min.
- [ ] (review) Health-permission-denied path: on a fresh install, DENY the
      HealthKit prompt → session must NOT start; app stays on the start
      screen with a persistent "Health authorization failed" message (no
      phantom "running" session).
- [ ] (review) Double-tap Start rapidly: exactly one session starts (no
      duplicate refresh loops — watch for doubled network activity or
      double alerts later in the session).
- [ ] End Session returns to start screen; workout appears in the Fitness
      app afterwards.

## Data & display
- [ ] Session screen shows plausible forecast (range + trend) and nearest
      station (expect "KiteandYoga Mallorca", ~7 km, at the home spot) —
      cross-check numbers against windguru.cz.
- [ ] Live-reading age updates ("updated N min ago"); if the station feed
      is stale > 20 min the NOW block grays out.
- [ ] Cellular independence: iPhone powered off or left behind — data still
      refreshes over watch LTE.

## Failover chain (the resilience story, end to end)
- [ ] Stop the server container (`docker stop stallalert` on the OVH box)
      mid-session → within one 5-min tick the "direct" badge appears and
      data still updates (micro API + public station endpoints).
- [ ] Restart the server (`docker start stallalert`) → badge disappears
      within one tick.
- [ ] (review) Degraded-server mode: if the served forecast ever shows
      model "gfs-micro" while the service badge shows normal, the SERVER's
      Windguru cookie has expired — refresh WG_COOKIE per docs/deploy.md.
      (Not a watch bug; note it if seen.)
- [ ] 401 path: temporarily change the API token in Settings to garbage →
      app shows "Check service token" and does NOT switch to direct;
      restore the token afterwards.

- [ ] (review) Fully offline: enable airplane mode (or walk out of LTE
      coverage) mid-session → last-good data stays visible with honest ages
      and the "offline" badge; then set the threshold above the cached
      forecast's minimum → a PREDICTED alert still fires from cache within
      one tick. This is the direct verification of the offline-safety fix.
- [ ] (review) Time-to-first-data: after Start Session, the session screen
      populates within ~30 s (short retry cadence until first fix+fetch),
      not after a silent 5-minute wait.

## The alert (do this one on a calm day or with a raised threshold)
- [ ] Set threshold ABOVE current wind → within one tick the alert fires:
      strong haptics + audible tone repeating (~3 rounds), full-screen red
      view labeled "forecast" or "measured now".
- [ ] Tap OK: alarm stops, returns to session screen, does NOT re-fire on
      subsequent ticks while wind stays below threshold.
- [ ] Raise wind expectation (set threshold 2+ kn below current wind), wait
      one tick (re-arm), then set it above again → alert fires a second
      time (hysteresis re-arm works end to end).
- [ ] (review) Acknowledge under Water Lock: fire the alert while Water
      Lock is engaged → confirm you can actually silence it with wet hands
      (Water Lock blocks touch until crown-unlock; if silencing is too
      fiddly on the water, note it — we may need a crown-based acknowledge).

## Endurance
- [ ] 3-hour session (workout + GPS + LTE + 5-min ticks) ends with ≥ 25%
      battery remaining.
