# Station Override — Design Spec

**Date:** 2026-07-08
**Status:** Approved design, pre-implementation
**Extends:** 2026-07-06-stallalert-design.md (both systems deployed/merged)

## Purpose

The nearest station by haversine can be the wrong station in practice (other
side of a headland, different beach with different wind exposure). The rider
must be able to pick an alternative station from the nearby candidates, have
that choice remembered for that spot, see clearly that a manual choice is
active, and be able to reset to automatic.

## Decisions (made with the user)

| Decision | Choice |
|---|---|
| Persistence | Sticky **near the spot where chosen** (within 5 km); other locations stay auto-nearest; explicit reset to auto; visible "manual" marker (pin icon) while active |
| Picker location | Tap the NOW · station block on the start/session screens |
| Picker contents | Name + distance only (candidates come free from the server's cached station list; no extra Windguru traffic) |
| Architecture | A: client-owned override — server stays stateless, gains `station_id` param + `nearby_stations` payload field; the watch remembers per-spot choices and applies them on BOTH the service and direct-fallback paths |

## Server changes (`server/`)

### API (extends the frozen /v1/conditions contract, backward-compatibly)

`GET /v1/conditions?lat=..&lon=..[&station_id=N]`

- `station_id` present and **valid** (integer; exists in the adapter's cached
  station list; within 50 km of lat/lon): serve that station — reading
  fetched by id exactly as today; `name`/`distance_km` computed from the
  cached list entry. The payload's `station` object gains
  `"source": "manual"`.
- `station_id` absent, unknown, non-integer, or > 50 km away: auto-nearest
  exactly as today, `"source": "auto"`. (Silent, honest fallback: a stale
  override from another trip degrades to auto rather than erroring or lying.)
- Every payload gains `"nearby_stations": [{"id", "name", "distance_km"}]` —
  up to 6 stations within 30 km of lat/lon, ascending by distance, computed
  at serialization time from the adapter's 6-h-cached station list. Empty
  array when none.

### Implementation notes

- `Stallalert.Windguru.Adapter` behaviour gains two callbacks that read the
  cached list (no new HTTP): `stations_near(lat, lon, limit)` →
  `{:ok, [%{id, name, distance_km}]}` and `station_by_id(id, lat, lon)` →
  `{:ok, %{id, name, distance_km}} | {:ok, nil}` (nil = unknown or > 50 km).
- `Conditions.get/4` accepts `station_id \\ nil`. The cached station entry
  records the station id it was fetched for; a request whose resolved target
  id differs invalidates that entry immediately (same pattern as the existing
  > 2 km position invalidation) — switching stations takes effect next tick,
  not after TTL.
- `Router`: parse/validate the param (non-integer → treated as absent);
  serializer emits `source` and `nearby_stations`.
- `FakeAdapter` extended accordingly.

## Watch changes (`watch/`)

### StallAlertKit

- **`StationOverrideStore`** (new): persists entries
  `{lat, lon, stationID, stationName}` in UserDefaults.
  - `override(near: (lat, lon)) -> Entry?` — entry whose spot is within
    **5 km** (haversine) of the position; nearest entry wins if several.
  - `set(_ entry:)` — replaces any existing entry within 5 km (one choice
    per beach); otherwise appends.
  - `clearNear(_ position:)` — removes the entry within 5 km (reset to auto).
  - Pure logic + injectable defaults; fully unit-tested (radius boundary,
    replace, clear, multiple spots).
- **Models:** `Conditions` gains `nearbyStations: [NearbyStation]?`
  (`NearbyStation = {id, name, distanceKm}`); `Station` gains
  `source: String?` ("manual"/"auto"). Both optional → old payloads and
  fixtures still decode.
- **`WindDataProvider.fetch(lat:lon:stationID:)`** — protocol gains the
  optional override id; threaded through all three providers and test fakes.
  - `ServiceClient`: appends `station_id` query item when non-nil.
  - `DirectWindguruClient`: when non-nil, skips nearest-resolution and
    fetches that id (name/distance from its cached station list; unknown id
    or > 50 km → auto-nearest, `source: "auto"`, mirroring the server). It
    also populates `nearbyStations` from its cached list (≤ 6 within 30 km)
    so the picker works in fallback mode. Sets `source` accordingly.
  - `FailoverProvider`: pass-through.

### App layer

- `SessionController`: each tick looks up
  `StationOverrideStore.override(near: currentPosition)` and passes the id
  to `fetch`; exposes the latest `nearbyStations` and whether the served
  station's `source == "manual"`.
- **Picker UI:** the NOW · station block (SessionView and StartView) becomes
  a Button → sheet (`StationPickerView`): first row **"Auto (nearest)"**,
  then candidate rows "name — X.X km", checkmark on the active choice.
  Selecting a station writes the override (with current GPS position) and
  triggers an immediate `refreshTick`; Auto calls `clearNear` + refresh.
- **Manual marker:** a small pin icon (SF Symbol `pin.fill`) next to the
  station name, shown only when an override is stored for this spot AND the
  served payload confirms `source == "manual"`. If the server rejected the
  override, the pin disappears (honest auto state).
- Dead/quiet chosen station: existing staleness handling applies unchanged
  (gray-out > 20 min; alerts continue forecast-driven). AlertPolicy is
  untouched.

## Error handling

- Unknown/far override id: both server and direct client silently serve
  auto-nearest with `source: "auto"`; the watch's pin icon disappears.
- Override station silent: normal staleness path (never blocks alerts).
- Old server + new watch (or vice versa): all new fields optional; missing
  `nearby_stations` → picker shows only "Auto (nearest)" with a "no
  candidates" note.

## Testing

- Server (ExUnit): param validation matrix (valid/unknown/non-integer/far),
  source echo, override-switch cache invalidation, nearby_stations shape and
  30 km/6 cap, FakeAdapter coverage.
- Watch (XCTest): StationOverrideStore semantics (5 km boundary, replace,
  clear, multi-spot); ServiceClient query param; DirectWindguruClient
  override path, rejection fallback, candidates list; decoder
  backward-compat (fixtures without new fields).
- Hardware checklist addition: pick the 2nd-nearest station → pin appears,
  readings switch within one tick; reset to Auto → pin gone; walk/drive away
  > 5 km (or simulate) → auto-nearest returns.

## Out of scope

Per-candidate live wind in the picker (costs N station calls per refresh);
liveness tags; naming/managing favorite spots; any server-side persistence.
