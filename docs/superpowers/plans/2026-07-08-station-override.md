# Station Override Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the rider pick an alternative wind station from nearby candidates, remembered per spot, applied on both the server and direct-fallback data paths, with a visible manual marker and reset-to-auto.

**Architecture:** Client-owned override (spec 2026-07-08-station-override-design.md). The server stays stateless: `/v1/conditions` gains an optional `station_id` param and a free `nearby_stations` payload list (both computed from the adapter's 6-h-cached station list). The watch owns per-spot memory in a new `StationOverrideStore` and threads the id through `WindDataProvider`.

**Tech Stack:** existing — Elixir (server/), Swift 6 strict concurrency (watch/StallAlertKit + watch/App). No new dependencies on either side.

## Global Constraints

- Override validity bound: station must exist in the cached list AND be **≤ 50 km** from the requested lat/lon; otherwise silently fall back to auto-nearest with `source: "auto"`.
- Candidates: up to **6** stations within **30 km**, ascending by distance.
- Watch stickiness radius: **5 km** (haversine) around the spot where the override was chosen; one entry per ~5 km cluster.
- All new payload fields optional / backward-compatible: old payloads and committed fixtures must still decode.
- Server: repo norms hold — `mix test --warnings-as-errors` and `mix format --check-formatted` green; deps frozen (plug/bandit/req/jason); no Mox (config-injected FakeAdapter).
- Watch: `swift test` green with zero warnings; app builds via `xcodebuild -project watch/StallAlert.xcodeproj -scheme StallAlert -destination 'generic/platform=watchOS Simulator' build`. **Do NOT run `xcodegen generate` unless project.yml changes** (it wipes the user's pasted scheme env values); no project.yml change is needed in this plan (no new app-target files except Swift sources under App/, which ARE picked up… CAUTION: xcodegen globs are baked at generation time — adding `watch/App/Views/StationPickerView.swift` REQUIRES regenerating. Task 8 therefore MUST regenerate and MUST warn the user to re-add scheme env values afterward, or add the file under the existing compiled sources via Xcode. See Task 8 Step 0.)
- Wind speeds knots, distances km, `distance_km` rounded to 0.1 (server) as today.

---

### Task 1: Server — adapter station queries (`stations_near/3`, `station_by_id/3`)

**Files:**
- Modify: `server/lib/stallalert/windguru/adapter.ex` (add 2 callbacks)
- Modify: `server/lib/stallalert/windguru/http_adapter.ex`
- Modify: `server/test/support/fake_adapter.ex`
- Test: `server/test/stallalert/windguru/http_adapter_test.exs` (extend)

**Interfaces:**
- Consumes: the existing cached-station-list machinery in `http_adapter.ex` (`fetch_station_list/0`, persistent_term cache, `Stallalert.Geo.distance_km/2`) and `StationParser.parse_station_list/1`.
- Produces (Tasks 2–3 rely on these exact shapes):

```elixir
@callback stations_near(lat :: float, lon :: float, limit :: pos_integer) ::
            {:ok, [%{id: integer, name: String.t(), distance_km: float}]} | {:error, term}
@callback station_by_id(id :: integer, lat :: float, lon :: float) ::
            {:ok, %{id: integer, name: String.t(), distance_km: float}} | {:ok, nil} | {:error, term}
```

`stations_near` returns stations within **30 km**, ascending by distance, at most `limit`; `station_by_id` returns nil for unknown ids or ids farther than **50 km**. Both read the cached list only — no new HTTP beyond the existing 6-h refresh.

- [ ] **Step 1: Write failing tests** (append to `http_adapter_test.exs`, reusing its stub/setup patterns and the real `stations_list.json` fixture; read the fixture to pick REAL ids/coords for exact assertions — the entries near lat 39.92 / lon 3.09 include station 4048 "KiteandYoga Mallorca" at ~6.9 km):

```elixir
  describe "stations_near/3" do
    test "returns nearest-first candidates within 30 km, capped at limit" do
      stub_station_list_fixture()   # same stub used by the nearest_station tests
      assert {:ok, stations} = HTTPAdapter.stations_near(39.92, 3.09, 6)
      assert length(stations) >= 1 and length(stations) <= 6
      assert [%{id: _, name: _, distance_km: _} | _] = stations
      distances = Enum.map(stations, & &1.distance_km)
      assert distances == Enum.sort(distances)
      assert Enum.all?(distances, &(&1 <= 30.0))
      assert hd(stations).id == 4048   # verify against the fixture before finalizing
    end

    test "empty when nothing within 30 km" do
      stub_station_list_fixture()
      assert {:ok, []} = HTTPAdapter.stations_near(0.0, 0.0, 6)
    end
  end

  describe "station_by_id/3" do
    test "returns the station with distance when known and within 50 km" do
      stub_station_list_fixture()
      assert {:ok, %{id: 4048, name: name, distance_km: d}} =
               HTTPAdapter.station_by_id(4048, 39.92, 3.09)
      assert is_binary(name) and d < 50.0
    end

    test "nil for unknown id" do
      stub_station_list_fixture()
      assert {:ok, nil} = HTTPAdapter.station_by_id(999_999_999, 39.92, 3.09)
    end

    test "nil for a known id farther than 50 km" do
      stub_station_list_fixture()
      # pick a REAL far-away id from the fixture (the trimmed list contains
      # Argentina/Miami/etc. entries) and assert nil from Mallorca coords
      assert {:ok, nil} = HTTPAdapter.station_by_id(<far_id_from_fixture>, 39.92, 3.09)
    end
  end
```

(`stub_station_list_fixture/0`: extract the existing station-list stub into a named private helper if the current tests inline it — pure test refactor, keep behavior identical. Replace `<far_id_from_fixture>` with a real id read from the fixture.)

- [ ] **Step 2: Run to verify failure**

Run: `cd server && mix test test/stallalert/windguru/http_adapter_test.exs`
Expected: FAIL — undefined functions.

- [ ] **Step 3: Implement** in `http_adapter.ex`, reusing the cached list:

```elixir
  @candidate_radius_km 30.0
  @override_max_km 50.0

  @impl true
  def stations_near(lat, lon, limit) do
    with {:ok, stations} <- fetch_station_list() do
      {:ok,
       stations
       |> Enum.map(&%{id: &1.id, name: &1.name, distance_km: Geo.distance_km({&1.lat, &1.lon}, {lat, lon})})
       |> Enum.filter(&(&1.distance_km <= @candidate_radius_km))
       |> Enum.sort_by(& &1.distance_km)
       |> Enum.take(limit)
       |> Enum.map(&%{&1 | distance_km: Float.round(&1.distance_km, 1)})}
    end
  end

  @impl true
  def station_by_id(id, lat, lon) do
    with {:ok, stations} <- fetch_station_list() do
      case Enum.find(stations, &(&1.id == id)) do
        nil -> {:ok, nil}
        s ->
          d = Geo.distance_km({s.lat, s.lon}, {lat, lon})
          if d <= @override_max_km,
            do: {:ok, %{id: s.id, name: s.name, distance_km: Float.round(d, 1)}},
            else: {:ok, nil}
      end
    end
  end
```

(Adjust to `fetch_station_list/0`'s actual return shape — it may return the parsed list directly; match the existing `nearest_station/2` usage.) Add both callbacks to `adapter.ex` exactly as in the Interfaces block. Extend `FakeAdapter` with both (persistent_term-settable like its other responses; healthy defaults: `stations_near` → `[%{id: 1, name: "TestStn", distance_km: 1.2}, %{id: 2, name: "OtherBeach", distance_km: 4.7}]`, `station_by_id` → echoes `%{id: id, name: "Chosen", distance_km: 3.3}` for ids 1/2/77, nil otherwise — and register the new keys in `FakeAdapter.reset/0`).

- [ ] **Step 4: Full suite green**

Run: `cd server && mix test --warnings-as-errors && mix format --check-formatted`

- [ ] **Step 5: Commit**

```bash
git add server && git commit -m "feat(server): adapter station queries for override and candidates"
```

---

### Task 2: Server — override-aware Conditions cache

**Files:**
- Modify: `server/lib/stallalert/conditions.ex`
- Test: `server/test/stallalert/conditions_test.exs` (extend)

**Interfaces:**
- Consumes: `station_by_id/3`, `stations_near/3`, `nearest_station/2` from the adapter behaviour.
- Produces: `Stallalert.Conditions.get(server \\ __MODULE__, lat, lon, opts \\ [])` — `opts[:station_id]` optional integer. Payload map gains `source: "manual" | "auto"` inside the station map and a top-level `nearby_stations: [%{id, name, distance_km}]`. **Signature note:** the existing `get(server \\ __MODULE__, lat, lon)` becomes `get(server \\ __MODULE__, lat, lon, opts \\ [])` — existing 2- and 3-arity call sites keep working unchanged.

Semantics (all must hold):
1. `station_id` valid (adapter `station_by_id` returns a map): serve that station's reading; station map carries the resolved name/distance and `source: "manual"`.
2. `station_id` nil/unknown/far (`{:ok, nil}`): auto-nearest exactly as today, `source: "auto"`.
3. **Switch invalidation:** the cached station entry records the id it was fetched for; if the newly resolved target id differs, the entry is expired immediately (mirror the existing >2 km position-invalidation pattern in `refresh_entry`).
4. `nearby_stations` computed on every `get` via `stations_near(lat, lon, 6)` (cheap cache read); on adapter error → `[]` (never fails the payload).

- [ ] **Step 1: Write failing tests** (append to `conditions_test.exs`, following its `start_supervised!`/FakeAdapter patterns):

```elixir
  test "override station_id is honored and marked manual", %{pid: pid} do
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04, station_id: 77)
    assert c.station.id == 77
    assert c.station.source == "manual"
  end

  test "unknown override falls back to auto-nearest", %{pid: pid} do
    Stallalert.FakeAdapter.set(:station_by_id, {:ok, nil})
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04, station_id: 424_242)
    assert c.station.name == "TestStn"
    assert c.station.source == "auto"
  end

  test "no override is auto", %{pid: pid} do
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    assert c.station.source == "auto"
  end

  test "switching override invalidates the cached station entry immediately", %{pid: pid} do
    assert {:ok, c1} = Conditions.get(pid, 52.36, 5.04, station_id: 1)
    assert c1.station.id == 1
    # within TTL, different target -> must refetch, not serve cached station 1
    assert {:ok, c2} = Conditions.get(pid, 52.36, 5.04, station_id: 2)
    assert c2.station.id == 2
    # and back to auto also switches (nearest is id 1 per FakeAdapter default)
    assert {:ok, c3} = Conditions.get(pid, 52.36, 5.04)
    assert c3.station.id == 1
    assert c3.station.source == "auto"
  end

  test "payload always carries nearby_stations", %{pid: pid} do
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    assert [%{id: _, name: _, distance_km: _} | _] = c.nearby_stations
  end

  test "nearby_stations degrades to empty list on adapter error", %{pid: pid} do
    Stallalert.FakeAdapter.set(:stations_near, {:error, :boom})
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    assert c.nearby_stations == []
  end
```

(FakeAdapter's `station_by_id` default must echo the requested id for ids 1, 2 and 77 — set in Task 1. Also make its `station_reading` default work for any id, as it already does.)

- [ ] **Step 2: Run to verify failure**, then **Step 3: Implement** in `conditions.ex`: extend `get` per the Interfaces note; thread `station_id` through `handle_call` into `maybe_refresh`; resolve the target BEFORE the freshness check (`station_by_id` when override given and non-nil result, else `nearest_station`); store `target_id` + `source` on the station entry; expire the entry when `entry.target_id != resolved.id`; in `build_payload`, merge `source` into the station map and add `nearby_stations` (call `stations_near(lat, lon, 6)` in `handle_call`, pass into `build_payload`; `{:error, _}` → `[]`). Follow the file's existing entry-struct and invalidation idioms exactly.

- [ ] **Step 4: Full suite + format green**, then **Step 5: Commit**

```bash
git add server && git commit -m "feat(server): override-aware conditions cache with nearby candidates"
```

---

### Task 3: Server — router param + serialization

**Files:**
- Modify: `server/lib/stallalert/router.ex`
- Test: `server/test/stallalert/router_test.exs` (extend)

**Interfaces:**
- Consumes: `Conditions.get(lat, lon, station_id: id)` (Task 2).
- Produces the extended wire contract (watch Tasks 4–7 decode this):

```json
"station": {"id": 1, "name": "TestStn", "distance_km": 1.2, "source": "manual", "reading": {...}},
"nearby_stations": [{"id": 1, "name": "TestStn", "distance_km": 1.2}, ...]
```

- [ ] **Step 1: Failing router tests** (append; bearer-token patterns as the file already does):

```elixir
    test "station_id param is honored and echoed as manual" do
      conn = authed_get("/v1/conditions?lat=52.36&lon=5.04&station_id=77")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["station"]["id"] == 77
      assert body["station"]["source"] == "manual"
    end

    test "non-integer station_id is treated as absent" do
      conn = authed_get("/v1/conditions?lat=52.36&lon=5.04&station_id=abc")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["station"]["source"] == "auto"
    end

    test "payload includes nearby_stations" do
      conn = authed_get("/v1/conditions?lat=52.36&lon=5.04")
      body = Jason.decode!(conn.resp_body)
      assert [%{"id" => _, "name" => _, "distance_km" => _} | _] = body["nearby_stations"]
    end
```

(Add an `authed_get/1` private helper if the file doesn't have one — pure test refactor of the repeated `conn(:get, ...) |> put_req_header(...) |> call`.) Ensure `FakeAdapter.reset()` in setup covers the two new keys (done in Task 1).

- [ ] **Step 2: Verify failure**, then **Step 3: Implement**: in the `/v1/conditions` route, parse `station_id` with `Integer.parse/1` — only a full-integer string counts (`{id, ""}`), anything else → nil; call `Conditions.get(lat, lon, station_id: id)`; the serializer passes `station` (now containing `source`) and adds `nearby_stations` from the payload. Keep the existing hour-trimming untouched.

- [ ] **Step 4: Full suite + format green**, then **Step 5: Commit**

```bash
git add server && git commit -m "feat(server): station_id param and nearby_stations in conditions API"
```

---

### Task 4: Watch — models for the extended contract

**Files:**
- Modify: `watch/StallAlertKit/Sources/StallAlertKit/Models.swift`
- Test: `watch/StallAlertKit/Tests/StallAlertKitTests/ModelsTests.swift` (extend)

**Interfaces (later tasks rely on these exact names):**

```swift
public struct NearbyStation: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let distanceKm: Double
    public init(id: Int, name: String, distanceKm: Double)
}
// Station gains:            public let source: String?        // "manual" | "auto" | nil (old payloads)
// Conditions gains:         public let nearbyStations: [NearbyStation]?
```

Both new fields optional; update the memberwise inits (existing call sites in tests/clients pass the new params — give them `source: nil` / `nearbyStations: nil` defaults in the init signatures so existing call sites compile unchanged: `init(..., source: String? = nil)` etc.).

- [ ] **Step 1: Failing tests**: (a) the existing `conditions.json` fixture (no new fields) still decodes, `c.nearbyStations == nil`, `c.station?.source == nil`; (b) an inline JSON with `"source": "manual"` and a 2-entry `"nearby_stations"` decodes with exact values.
- [ ] **Step 2: Verify failure → Step 3: Implement → Step 4: `swift test` green (all existing tests must pass unchanged) → Step 5: Commit**

```bash
git add watch && git commit -m "feat(watch): decode station source and nearby candidates"
```

---

### Task 5: Watch — StationOverrideStore (+ shared GeoMath)

**Files:**
- Create: `watch/StallAlertKit/Sources/StallAlertKit/StationOverrideStore.swift`
- Create: `watch/StallAlertKit/Sources/StallAlertKit/GeoMath.swift`
- Modify: `watch/StallAlertKit/Sources/StallAlertKit/DirectWindguruClient.swift` (replace its private haversine with GeoMath — behavior identical)
- Test: `watch/StallAlertKit/Tests/StallAlertKitTests/StationOverrideStoreTests.swift`

**Interfaces:**

```swift
public enum GeoMath {
    public static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double
}
public struct StationOverride: Codable, Equatable, Sendable {
    public let lat: Double
    public let lon: Double
    public let stationID: Int
    public let stationName: String
    public init(lat: Double, lon: Double, stationID: Int, stationName: String)
}
public final class StationOverrideStore: @unchecked Sendable {   // NSLock around entries
    public init(defaults: UserDefaults = .standard)
    public func override(nearLat: Double, lon: Double) -> StationOverride?  // within 5 km; nearest wins
    public func set(_ entry: StationOverride)     // replaces any entry within 5 km of entry's spot
    public func clearNear(lat: Double, lon: Double)  // removes the entry within 5 km, if any
}
```

Persistence: JSON-encoded `[StationOverride]` under UserDefaults key `"station_overrides"`.

- [ ] **Step 1: Failing tests** (use `UserDefaults(suiteName: #function)` + `removePersistentDomain`, as SettingsTests does):

```swift
func testNoOverrideByDefault()                    // override(near:) == nil
func testSetAndLookupWithin5km()                  // set at (39.92,3.09); lookup at 39.93,3.10 (~1.4 km) -> entry
func testNoMatchBeyond5km()                       // lookup at 39.97,3.09 (~5.6 km) -> nil
func testSetWithin5kmReplaces()                   // set A then B 1 km away -> one entry, B's station
func testTwoSpotsCoexist()                        // set at Mallorca and at (52.36,5.04) -> each found near its own spot
func testClearNearRemovesOnlyThatSpot()           // clear at Mallorca -> nil there, other spot intact
func testPersistsAcrossInstances()                // new store instance, same suite -> entry still found
```

(Compute the test coordinate offsets with 0.01° lat ≈ 1.11 km, as the cache-radius tests did.)

- [ ] **Step 2: Verify failure → Step 3: Implement** (straightforward: load/save helpers under the lock; `override(near:)` filters ≤ 5 km and picks min-distance; `set` = clearNear(entry spot) + append; module constant `private let stickinessKm = 5.0`). GeoMath: move the exact haversine implementation out of `DirectWindguruClient` (public), point the client at it, no numeric changes.
- [ ] **Step 4: `swift test` green (incl. all existing DirectWindguruClient cache tests — proves the refactor changed nothing) → Step 5: Commit**

```bash
git add watch && git commit -m "feat(watch): per-spot station override store with shared geo math"
```

---

### Task 6: Watch — thread stationID through the providers

**Files:**
- Modify: `watch/StallAlertKit/Sources/StallAlertKit/WindDataProvider.swift`
- Modify: `watch/StallAlertKit/Sources/StallAlertKit/ServiceClient.swift`
- Modify: `watch/StallAlertKit/Sources/StallAlertKit/FailoverProvider.swift`
- Test: `watch/StallAlertKit/Tests/StallAlertKitTests/ServiceClientTests.swift`, `FailoverProviderTests.swift` (extend/adjust)

**Interfaces:**

```swift
public protocol WindDataProvider: Sendable {
    func fetch(lat: Double, lon: Double, stationID: Int?) async throws -> Conditions
}
public extension WindDataProvider {   // convenience keeps existing call sites/tests compiling
    func fetch(lat: Double, lon: Double) async throws -> Conditions {
        try await fetch(lat: lat, lon: lon, stationID: nil)
    }
}
```

- `ServiceClient`: appends `URLQueryItem(name: "station_id", value: String(id))` only when non-nil.
- `FailoverProvider.fetch(lat:lon:stationID:)`: passes the id through to whichever leg serves the tick (semantics otherwise byte-identical — do not touch the failover logic).
- `DirectWindguruClient`: satisfy the new protocol requirement with a `stationID` parameter that this task merely accepts and ignores (`_ = stationID` placeholder is NOT allowed — instead pass it into the internal station-leg entry point as an unused-but-typed argument; Task 7 gives it behavior. Keep the compile green here with the parameter plumbed to the station leg, defaulting to existing auto behavior when nil OR non-nil — Task 7 adds the non-nil branch).

- [ ] **Step 1: Failing/adjusted tests**: ServiceClient — new test `testFetchIncludesStationIDWhenSet` asserting the query contains `station_id=4048` when passed, and extend the existing happy-path test to assert `station_id` is ABSENT when nil. FailoverProvider — extend one existing test's fake to record the received stationID and assert pass-through on both the service and direct legs.
- [ ] **Step 2: Verify failure → Step 3: Implement → Step 4: full `swift test` green → Step 5: Commit**

```bash
git add watch && git commit -m "feat(watch): thread station override through the provider protocol"
```

---

### Task 7: Watch — DirectWindguruClient override + candidates

**Files:**
- Modify: `watch/StallAlertKit/Sources/StallAlertKit/DirectWindguruClient.swift`
- Test: `watch/StallAlertKit/Tests/StallAlertKitTests/DirectWindguruClientTests.swift` (extend)

**Interfaces:**
- Consumes: cached station list (existing 6-h cache), `GeoMath`, models from Task 4.
- Produces: direct-path behavior mirroring the server —
  - `stationID` non-nil and found in the cached list within **50 km** → fetch THAT station's reading; `Station.source = "manual"`.
  - unknown/far → auto-nearest as today, `source = "auto"`.
  - every successful fetch populates `Conditions.nearbyStations` (≤ 6 within 30 km, ascending, from the cached list; distances rounded 0.1).

- [ ] **Step 1: Failing tests** (existing stub patterns; real fixture):

```swift
func testOverrideStationIsFetchedAndMarkedManual()   // stationID: <2nd-nearest real id from fixture> -> station.id == it, source == "manual"
func testUnknownOverrideFallsBackToAuto()            // stationID: 999999999 -> nearest (4048), source == "auto"
func testFarOverrideFallsBackToAuto()                // a real far id (Argentina entry) -> auto
func testNearbyStationsPopulated()                   // fetch -> nearbyStations first == 4048, all ≤ 30 km, ascending, count ≤ 6
func testExistingAutoPathNowCarriesSource()          // plain fetch -> station.source == "auto"
```

(Read the fixture to pick the real 2nd-nearest id to 39.92/3.09 and a real far id; assert exact values.)

- [ ] **Step 2: Verify failure → Step 3: Implement** (the station-leg entry point gains the branch; candidates built next to the existing nearest-resolution; respect the existing graceful-degradation rule — station-leg failures still yield `station: nil`, and in that case `nearbyStations` should still be populated if the list fetch succeeded) → **Step 4: full `swift test` green → Step 5: Commit**

```bash
git add watch && git commit -m "feat(watch): direct-path station override and candidate list"
```

---

### Task 8: Watch — SessionController wiring + picker UI

**Files:**
- Modify: `watch/App/SessionController.swift`
- Modify: `watch/App/Views/SessionView.swift`, `watch/App/Views/StartView.swift`
- Create: `watch/App/Views/StationPickerView.swift`
- Modify (regeneration only): `watch/StallAlert.xcodeproj` via `xcodegen generate` — required because a NEW app-target source file is added.

**Interfaces:**
- Consumes: everything from Tasks 4–7.
- Produces (UI contract from the spec): tappable station block → picker sheet ("Auto (nearest)" first, then "name — X.X km" rows, checkmark on active choice); pin icon (`pin.fill`) beside the station name only when an override is stored for this spot AND the served payload says `source == "manual"`; picking/reset triggers an immediate refresh.

- [ ] **Step 0: Scheme-preservation warning (do this FIRST).** `xcodegen generate` wipes the user's pasted scheme environment variables (credential seeding). Before regenerating: `cp watch/StallAlert.xcodeproj/xcshareddata/xcschemes/StallAlert.xcscheme /tmp/StallAlert.xcscheme.bak`. After regenerating: copy the `<EnvironmentVariables>` block back into the fresh scheme (or restore the whole file if xcodegen didn't change scheme structure). Verify with `grep -c STALLALERT_ watch/StallAlert.xcodeproj/xcshareddata/xcschemes/StallAlert.xcscheme` → 4.

- [ ] **Step 1: SessionController** — add:

```swift
private let overrideStore = StationOverrideStore()
private(set) var nearbyStations: [NearbyStation] = []
private(set) var manualStationActive = false

// in refreshTick, before fetching:
let override = locationManager.location.flatMap {
    overrideStore.override(nearLat: $0.coordinate.latitude, lon: $0.coordinate.longitude)
}
// pass override?.stationID into provider.fetch(lat:lon:stationID:)
// after a successful fetch:
nearbyStations = c.nearbyStations ?? []
manualStationActive = (override != nil) && (c.station?.source == "manual")

// selection API used by the picker:
func selectStation(_ s: NearbyStation) { /* store.set(StationOverride(at current location, s.id, s.name)); Task { await refreshTick() } */ }
func selectAutoStation() { /* store.clearNear(current location); Task { await refreshTick() } */ }
```

(Write the real implementations, guarding on `locationManager.location != nil`; no-ops without a fix.)

- [ ] **Step 2: StationPickerView** (new file, complete):

```swift
import SwiftUI
import StallAlertKit

struct StationPickerView: View {
    @Environment(SessionController.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Button {
                session.selectAutoStation(); dismiss()
            } label: {
                HStack {
                    Text("Auto (nearest)")
                    Spacer()
                    if !session.manualStationActive { Image(systemName: "checkmark") }
                }
            }
            if session.nearbyStations.isEmpty {
                Text("No candidates yet").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(session.nearbyStations, id: \.id) { s in
                Button {
                    session.selectStation(s); dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.name).lineLimit(1)
                            Text("\(s.distanceKm, specifier: "%.1f") km")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.manualStationActive && session.conditions?.station?.id == s.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .navigationTitle("Station")
    }
}
```

- [ ] **Step 3: Station block → Button + pin.** In `SessionView` (and the station line in `StartView` if present), wrap the NOW · station block in a `Button` toggling `@State private var showStationPicker = false` → `.sheet(isPresented: $showStationPicker) { StationPickerView() }`, and add beside the station name: `if session.manualStationActive { Image(systemName: "pin.fill").font(.caption2) }`. Keep all existing coloring/age logic untouched.

- [ ] **Step 4: Regenerate + build + package tests**

```bash
cd watch && xcodegen generate && <restore scheme env block per Step 0> && \
xcodebuild -project StallAlert.xcodeproj -scheme StallAlert -destination 'generic/platform=watchOS Simulator' build
cd StallAlertKit && swift test
```
Expected: BUILD SUCCEEDED; all package tests green. Optionally launch in a watch simulator and screenshot the picker.

- [ ] **Step 5: Commit**

```bash
git add watch && git commit -m "feat(watch): station picker with per-spot override and manual pin"
```

---

### Task 9: Deploy server + docs

**Files:**
- Modify: `docs/hardware-checklist.md`, `docs/deploy.md` (API contract note)

- [ ] **Step 1: Redeploy the server** (user's OVH box, per docs/deploy.md "Current production deployment"): `ssh stallalert@51.255.64.127`, `cd ~/stallalert && git pull`, `cd server && docker build -t stallalert-server .`, `docker stop stallalert && docker rm stallalert`, re-run the documented `docker run` with `--env-file ~/stallalert-deploy.env`. Verify: `curl -s localhost:4000/v1/health` then an authed conditions call WITH `&station_id=<a nearby id>` → `"source":"manual"`, and without → `"nearby_stations"` present. (This step needs the user at the keyboard for SSH.)
- [ ] **Step 2: Docs.** deploy.md: add the two new contract elements to the verify example. hardware-checklist.md: add under "Data & display": pick the 2nd-nearest station → pin appears and readings switch within one tick; reset to Auto → pin gone; > 5 km away the override no longer applies.
- [ ] **Step 3: Commit**

```bash
git add docs && git commit -m "docs: station override deploy verification and checklist items"
```
