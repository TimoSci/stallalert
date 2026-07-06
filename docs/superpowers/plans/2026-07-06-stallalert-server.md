# StallAlert Server (Elixir Intermediary) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A self-hosted Elixir service that logs into Windguru, caches normalized forecast + nearest-station data, and serves it to the watch as one small authenticated JSON payload.

**Architecture:** Plug + Bandit HTTP app with a supervised GenServer (`Stallalert.Conditions`) that polls Windguru on a schedule and answers watch requests from an in-memory cache. A single `Stallalert.Windguru.*` adapter layer is the only code that knows Windguru's formats.

**Tech Stack:** Elixir ~> 1.17, Plug ~> 1.16, Bandit ~> 1.5, Req ~> 0.5, Jason ~> 1.4. Docker (multi-stage, mix release) for deployment. Caddy for TLS.

## Global Constraints

- All wind speeds in **knots**, directions in **degrees**, times as **UTC ISO-8601** in JSON / `DateTime` in code.
- JSON keys are **snake_case**.
- Runtime configuration ONLY via env vars: `WG_USERNAME`, `WG_PASSWORD`, `API_TOKEN`, `PORT` (default 4000).
- Dependencies limited to: plug, bandit, req, jason. No Phoenix, no Mox (use config-injected fake modules).
- Refresh cadence: forecast every **15 min**, station reading every **5 min**; cache entries older than interval + **10 min grace** are served with `"stale": true`.
- Elixir app name: `:stallalert`, module prefix `Stallalert`, in directory `server/`.
- Parse failures must return `{:error, :unexpected_format}` — never raise out of the adapter, never return zeros.

## API contract (consumed by the watch app — do not change without updating the watch plan)

```
GET /v1/health                          -> 200 {"status":"ok"}   (no auth)
GET /v1/conditions?lat=52.36&lon=5.04   -> 200 (Authorization: Bearer <API_TOKEN>)
{
  "generated_at": "2026-07-06T10:00:00Z",
  "stale": false,
  "forecast": {
    "model": "wg",
    "init_time": "2026-07-06T06:00:00Z",
    "hours": [
      {"time": "2026-07-06T10:00:00Z", "wind_kn": 14.2, "gust_kn": 21.0, "dir_deg": 225.0},
      ... (next 12 steps)
    ]
  },
  "station": {                            // null when no station within 30 km
    "id": 1234, "name": "Ijburg", "distance_km": 1.2,
    "reading": {"time": "2026-07-06T09:55:00Z", "wind_kn": 15.5, "gust_kn": 20.1, "dir_deg": 230.0}
  }
}
401 on bad/missing token. 422 on missing/invalid lat/lon. 503 when no data has ever been fetched.
```

---

### Task 1: Capture real Windguru payloads as test fixtures

**Requires the user's Windguru PRO credentials and a browser session — this is a human-in-the-loop discovery task.** Everything downstream parses these fixtures, so field names in later tasks must be adjusted to what is actually captured here.

**Files:**
- Create: `server/scripts/capture_fixtures.sh`
- Create: `server/test/fixtures/windguru/forecast.json`
- Create: `server/test/fixtures/windguru/station_current.json`
- Create: `server/test/fixtures/windguru/stations_list.json`
- Create: `docs/windguru-api-notes.md`

**Interfaces:**
- Produces: the three fixture files above and `docs/windguru-api-notes.md` recording, for each endpoint: exact URL + query params, required headers (Referer, cookies), auth mechanism, and units of each field.

- [ ] **Step 1: Discover the endpoints in the browser**

Log into windguru.cz (PRO account) in a browser. Open DevTools → Network, filter `iapi`. Load (a) a spot forecast page, (b) a custom lat/lon forecast (PRO feature), (c) a station page with live data. Record every `iapi.php` request URL, its query params, and which cookies/headers it needs. Known candidates to confirm:
- `https://www.windguru.cz/int/iapi.php?q=forecast&id_model=...` (forecast JSON used by widgets)
- `https://www.windguru.cz/int/iapi.php?q=station_data_current&id_station=N` (live reading)
- a station-list/map endpoint returning stations with coordinates
- login: whatever request the login form makes (likely `iapi.php?q=user_login`)
Also capture the PRO micro API as fallback: `https://micro.windguru.cz/?lat=..&lon=..&u=$WG_USERNAME&p=$WG_SECONDARY_PASSWORD&m=wg` (text). Write all of it into `docs/windguru-api-notes.md`.

- [ ] **Step 2: Write the capture script**

```bash
#!/usr/bin/env bash
# server/scripts/capture_fixtures.sh
# Usage: WG_USERNAME=... WG_PASSWORD=... ./capture_fixtures.sh <lat> <lon> <station_id>
# Adjust URLs/params to match docs/windguru-api-notes.md before running.
set -euo pipefail
LAT=$1; LON=$2; STATION=$3
DIR="$(dirname "$0")/../test/fixtures/windguru"
mkdir -p "$DIR"
JAR=$(mktemp)
# 1. login (adjust endpoint/params per notes)
curl -sf -c "$JAR" "https://www.windguru.cz/int/iapi.php?q=user_login" \
  --data-urlencode "login=$WG_USERNAME" --data-urlencode "password=$WG_PASSWORD" \
  -H "Referer: https://www.windguru.cz/" > /dev/null
# 2. forecast for lat/lon, WG model (adjust params per notes)
curl -sf -b "$JAR" -H "Referer: https://www.windguru.cz/" \
  "https://www.windguru.cz/int/iapi.php?q=forecast&lat=$LAT&lon=$LON&id_model=wg" \
  | python3 -m json.tool > "$DIR/forecast.json"
# 3. live station reading
curl -sf -b "$JAR" -H "Referer: https://www.windguru.cz/" \
  "https://www.windguru.cz/int/iapi.php?q=station_data_current&id_station=$STATION" \
  | python3 -m json.tool > "$DIR/station_current.json"
# 4. stations near position (adjust endpoint per notes)
curl -sf -b "$JAR" -H "Referer: https://www.windguru.cz/" \
  "https://www.windguru.cz/int/iapi.php?q=stations&lat=$LAT&lon=$LON" \
  | python3 -m json.tool > "$DIR/stations_list.json"
# 5. micro API fallback (text; needs the PRO *secondary* password, WG_MICRO_PASSWORD)
curl -sf "https://micro.windguru.cz/?lat=$LAT&lon=$LON&u=$WG_USERNAME&p=$WG_MICRO_PASSWORD&m=wg" \
  > "$DIR/micro_forecast.txt"
rm -f "$JAR"
echo "Fixtures written to $DIR"
```

- [ ] **Step 3: Run it and sanity-check the fixtures**

Run: `WG_USERNAME=... WG_PASSWORD=... ./server/scripts/capture_fixtures.sh 52.36 5.04 <station_id>`
Expected: three valid JSON files. Open each; confirm wind speeds look like knots (compare against the website), timestamps are unix or ISO, direction is degrees. Note units per field in `docs/windguru-api-notes.md`. **Remove any session tokens, user ids, or email addresses from the fixtures before committing.**

- [ ] **Step 4: Commit**

```bash
git add server/scripts server/test/fixtures docs/windguru-api-notes.md
git commit -m "feat(server): capture windguru API fixtures and endpoint notes"
```

---

### Task 2: Scaffold the Elixir app with a /v1/health endpoint

**Files:**
- Create: `server/` via `mix new` (mix.exs, lib/stallalert/application.ex, .gitignore, etc.)
- Create: `server/lib/stallalert/router.ex`
- Test: `server/test/stallalert/router_test.exs`

**Interfaces:**
- Produces: `Stallalert.Router` (Plug.Router) mounted by Bandit in the supervision tree; `GET /v1/health` → 200 `{"status":"ok"}`.

- [ ] **Step 1: Generate the project and add deps**

```bash
cd /Users/me/Documents/code/stallalert
mix new server --app stallalert --sup
```

In `server/mix.exs` set deps:

```elixir
defp deps do
  [
    {:plug, "~> 1.16"},
    {:bandit, "~> 1.5"},
    {:req, "~> 0.5"},
    {:jason, "~> 1.4"}
  ]
end
```

Run: `cd server && mix deps.get`

- [ ] **Step 2: Write the failing router test**

```elixir
# server/test/stallalert/router_test.exs
defmodule Stallalert.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @opts Stallalert.Router.init([])

  test "GET /v1/health returns 200 ok without auth" do
    conn = conn(:get, "/v1/health") |> Stallalert.Router.call(@opts)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
  end

  test "unknown route returns 404" do
    conn = conn(:get, "/nope") |> Stallalert.Router.call(@opts)
    assert conn.status == 404
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/stallalert/router_test.exs`
Expected: FAIL — `Stallalert.Router` is undefined.

- [ ] **Step 4: Implement router and mount Bandit**

```elixir
# server/lib/stallalert/router.ex
defmodule Stallalert.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/v1/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok"}))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
```

In `server/lib/stallalert/application.ex`, set children:

```elixir
children = [
  {Bandit, plug: Stallalert.Router, port: String.to_integer(System.get_env("PORT") || "4000")}
]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test`
Expected: PASS. Also smoke-check: `mix run --no-halt &` then `curl -s localhost:4000/v1/health` → `{"status":"ok"}`; kill the server.

- [ ] **Step 6: Commit**

```bash
git add server
git commit -m "feat(server): scaffold elixir app with health endpoint"
```

---

### Task 3: Forecast parser (fixture-driven)

**Files:**
- Create: `server/lib/stallalert/windguru/forecast_parser.ex`
- Test: `server/test/stallalert/windguru/forecast_parser_test.exs`

**Interfaces:**
- Consumes: `server/test/fixtures/windguru/forecast.json` (Task 1).
- Produces: `Stallalert.Windguru.ForecastParser.parse(map) :: {:ok, forecast} | {:error, :unexpected_format}` where `forecast` is `%{model: "wg", init_time: DateTime.t(), hours: [%{time: DateTime.t(), wind_kn: float, gust_kn: float, dir_deg: float}]}` — hours sorted ascending, max 12 entries starting at the first step >= now is NOT applied here (parser returns the full timeline; trimming happens in the endpoint, Task 8).

- [ ] **Step 1: Write the failing test against the real fixture**

```elixir
# server/test/stallalert/windguru/forecast_parser_test.exs
defmodule Stallalert.Windguru.ForecastParserTest do
  use ExUnit.Case, async: true
  alias Stallalert.Windguru.ForecastParser

  @fixture "test/fixtures/windguru/forecast.json" |> File.read!() |> Jason.decode!()

  test "parses the captured fixture into a normalized timeline" do
    assert {:ok, f} = ForecastParser.parse(@fixture)
    assert f.model == "wg"
    assert %DateTime{} = f.init_time
    assert length(f.hours) > 0
    [first | _] = f.hours
    assert %DateTime{} = first.time
    assert is_number(first.wind_kn) and first.wind_kn >= 0
    assert is_number(first.gust_kn) and first.gust_kn >= first.wind_kn - 0.01
    assert is_number(first.dir_deg) and first.dir_deg >= 0 and first.dir_deg <= 360
    assert f.hours == Enum.sort_by(f.hours, & &1.time, DateTime)
  end

  test "rejects unexpected shapes" do
    assert {:error, :unexpected_format} = ForecastParser.parse(%{"foo" => 1})
    assert {:error, :unexpected_format} = ForecastParser.parse(%{"fcst" => %{"hours" => "nope"}})
  end
end
```

Tighten the first test with 2–3 exact expected values read manually from the fixture (e.g. `assert first.wind_kn == 14.2`) once you can see the file.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/stallalert/windguru/forecast_parser_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the parser**

Written against the widget-JSON shape (`fcst.initstamp` unix seconds, `fcst.hours` offsets in hours, parallel arrays `WINDSPD`/`GUST`/`SMER` in knots/degrees). **Adjust key names to the captured fixture; the normalized output shape must not change.**

```elixir
# server/lib/stallalert/windguru/forecast_parser.ex
defmodule Stallalert.Windguru.ForecastParser do
  @moduledoc "Parses windguru widget-JSON forecast into the normalized timeline."

  def parse(%{"fcst" => %{"initstamp" => init, "hours" => hours} = fcst})
      when is_integer(init) and is_list(hours) do
    with speeds when is_list(speeds) <- fcst["WINDSPD"],
         gusts when is_list(gusts) <- fcst["GUST"],
         dirs when is_list(dirs) <- fcst["SMER"] do
      steps =
        [hours, speeds, gusts, dirs]
        |> Enum.zip_with(fn [h, spd, gust, dir] ->
          %{
            time: DateTime.from_unix!(init + h * 3600),
            wind_kn: spd * 1.0,
            gust_kn: gust * 1.0,
            dir_deg: dir * 1.0
          }
        end)
        |> Enum.sort_by(& &1.time, DateTime)

      {:ok, %{model: "wg", init_time: DateTime.from_unix!(init), hours: steps}}
    else
      _ -> {:error, :unexpected_format}
    end
  end

  def parse(_), do: {:error, :unexpected_format}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/stallalert/windguru/forecast_parser_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/lib/stallalert/windguru server/test/stallalert/windguru
git commit -m "feat(server): normalized forecast parser from windguru fixture"
```

---

### Task 4: Station parsers (reading + station list with nearest-station selection)

**Files:**
- Create: `server/lib/stallalert/windguru/station_parser.ex`
- Create: `server/lib/stallalert/geo.ex`
- Test: `server/test/stallalert/windguru/station_parser_test.exs`
- Test: `server/test/stallalert/geo_test.exs`

**Interfaces:**
- Consumes: `station_current.json`, `stations_list.json` fixtures (Task 1).
- Produces:
  - `Stallalert.Windguru.StationParser.parse_reading(map) :: {:ok, %{time: DateTime.t(), wind_kn: float, gust_kn: float, dir_deg: float}} | {:error, :unexpected_format}`
  - `Stallalert.Windguru.StationParser.parse_station_list(map | list) :: {:ok, [%{id: integer, name: String.t(), lat: float, lon: float}]} | {:error, :unexpected_format}`
  - `Stallalert.Geo.distance_km({lat1, lon1}, {lat2, lon2}) :: float` (haversine)
  - `Stallalert.Geo.nearest(stations, {lat, lon}) :: {station, distance_km} | nil` — nil when list empty or nearest > 30 km.

- [ ] **Step 1: Write failing geo tests**

```elixir
# server/test/stallalert/geo_test.exs
defmodule Stallalert.GeoTest do
  use ExUnit.Case, async: true
  alias Stallalert.Geo

  test "haversine distance Amsterdam->Utrecht ~= 35 km" do
    d = Geo.distance_km({52.37, 4.90}, {52.09, 5.12})
    assert_in_delta d, 35.0, 2.0
  end

  test "nearest picks closest station and reports distance" do
    stations = [
      %{id: 1, name: "far", lat: 53.0, lon: 6.0},
      %{id: 2, name: "near", lat: 52.38, lon: 4.92}
    ]
    assert {%{id: 2}, d} = Geo.nearest(stations, {52.37, 4.90})
    assert d < 3.0
  end

  test "nearest returns nil when closest is beyond 30 km" do
    assert nil == Geo.nearest([%{id: 1, name: "far", lat: 55.0, lon: 8.0}], {52.37, 4.90})
  end

  test "nearest returns nil for empty list" do
    assert nil == Geo.nearest([], {52.37, 4.90})
  end
end
```

- [ ] **Step 2: Run to verify failure, then implement Geo**

Run: `mix test test/stallalert/geo_test.exs` — expect module-undefined failure. Then:

```elixir
# server/lib/stallalert/geo.ex
defmodule Stallalert.Geo do
  @earth_radius_km 6371.0
  @max_station_km 30.0

  def distance_km({lat1, lon1}, {lat2, lon2}) do
    dlat = deg2rad(lat2 - lat1)
    dlon = deg2rad(lon2 - lon1)
    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(deg2rad(lat1)) * :math.cos(deg2rad(lat2)) * :math.sin(dlon / 2) ** 2
    2 * @earth_radius_km * :math.asin(:math.sqrt(a))
  end

  def nearest([], _pos), do: nil

  def nearest(stations, pos) do
    {station, d} =
      stations
      |> Enum.map(&{&1, distance_km({&1.lat, &1.lon}, pos)})
      |> Enum.min_by(fn {_s, d} -> d end)

    if d <= @max_station_km, do: {station, d}, else: nil
  end

  defp deg2rad(deg), do: deg * :math.pi() / 180
end
```

Run: `mix test test/stallalert/geo_test.exs` — expect PASS.

- [ ] **Step 3: Write failing station parser tests (fixture-driven)**

```elixir
# server/test/stallalert/windguru/station_parser_test.exs
defmodule Stallalert.Windguru.StationParserTest do
  use ExUnit.Case, async: true
  alias Stallalert.Windguru.StationParser

  @reading "test/fixtures/windguru/station_current.json" |> File.read!() |> Jason.decode!()
  @list "test/fixtures/windguru/stations_list.json" |> File.read!() |> Jason.decode!()

  test "parses a live reading" do
    assert {:ok, r} = StationParser.parse_reading(@reading)
    assert %DateTime{} = r.time
    assert is_number(r.wind_kn) and is_number(r.gust_kn) and is_number(r.dir_deg)
  end

  test "parses the station list" do
    assert {:ok, [s | _]} = StationParser.parse_station_list(@list)
    assert is_integer(s.id) and is_binary(s.name)
    assert is_number(s.lat) and is_number(s.lon)
  end

  test "rejects unexpected shapes" do
    assert {:error, :unexpected_format} = StationParser.parse_reading(%{})
    assert {:error, :unexpected_format} = StationParser.parse_station_list(%{"x" => 1})
  end
end
```

- [ ] **Step 4: Run to verify failure, then implement**

Written against the expected `station_data_current` shape (`wind_avg`/`wind_max` knots, `wind_direction` degrees, `unixtime` seconds). **Adjust key names to the captured fixtures.**

```elixir
# server/lib/stallalert/windguru/station_parser.ex
defmodule Stallalert.Windguru.StationParser do
  def parse_reading(%{"wind_avg" => avg, "wind_max" => max, "wind_direction" => dir, "unixtime" => ts})
      when is_number(avg) and is_number(max) and is_number(dir) and is_integer(ts) do
    {:ok, %{time: DateTime.from_unix!(ts), wind_kn: avg * 1.0, gust_kn: max * 1.0, dir_deg: dir * 1.0}}
  end

  def parse_reading(_), do: {:error, :unexpected_format}

  def parse_station_list(%{"stations" => stations}) when is_list(stations) do
    parsed =
      for %{"id_station" => id, "station" => name, "lat" => lat, "lon" => lon} <- stations do
        %{id: id, name: name, lat: lat * 1.0, lon: lon * 1.0}
      end

    if parsed == [] and stations != [], do: {:error, :unexpected_format}, else: {:ok, parsed}
  end

  def parse_station_list(_), do: {:error, :unexpected_format}
end
```

Run: `mix test test/stallalert/windguru` — expect PASS.

- [ ] **Step 5: Commit**

```bash
git add server/lib/stallalert server/test/stallalert
git commit -m "feat(server): station parsers and nearest-station geo selection"
```

---

### Task 5: Windguru HTTP adapter

**Files:**
- Create: `server/lib/stallalert/windguru/adapter.ex` (behaviour)
- Create: `server/lib/stallalert/windguru/http_adapter.ex`
- Create: `server/config/config.exs`, `server/config/test.exs`
- Test: `server/test/stallalert/windguru/http_adapter_test.exs`

**Interfaces:**
- Consumes: parsers from Tasks 3–4; endpoint details from `docs/windguru-api-notes.md`.
- Produces the behaviour every caller depends on:

```elixir
defmodule Stallalert.Windguru.Adapter do
  @callback forecast(lat :: float, lon :: float) :: {:ok, map} | {:error, term}
  @callback nearest_station(lat :: float, lon :: float) ::
              {:ok, %{id: integer, name: String.t(), distance_km: float}} | {:ok, nil} | {:error, term}
  @callback station_reading(id :: integer) :: {:ok, map} | {:error, term}
end
```

  (`forecast/2` returns the Task 3 normalized forecast map; `station_reading/1` the Task 4 reading map.)

- [ ] **Step 1: Create the behaviour module and config**

Write `adapter.ex` exactly as above. Add config so tests can stub HTTP via Req's plug option:

```elixir
# server/config/config.exs
import Config
config :stallalert, windguru_req_options: []
import_config "#{config_env()}.exs"
```

```elixir
# server/config/test.exs
import Config
config :stallalert, windguru_req_options: [plug: {Req.Test, Stallalert.Windguru.HTTPAdapter}]
```

(Also create an empty `server/config/dev.exs` and `server/config/prod.exs` with just `import Config`.)

- [ ] **Step 2: Write failing adapter tests using Req.Test stubs and the fixtures**

```elixir
# server/test/stallalert/windguru/http_adapter_test.exs
defmodule Stallalert.Windguru.HTTPAdapterTest do
  use ExUnit.Case, async: true
  alias Stallalert.Windguru.HTTPAdapter

  @forecast "test/fixtures/windguru/forecast.json" |> File.read!() |> Jason.decode!()
  @reading "test/fixtures/windguru/station_current.json" |> File.read!() |> Jason.decode!()
  @stations "test/fixtures/windguru/stations_list.json" |> File.read!() |> Jason.decode!()

  test "forecast/2 fetches and normalizes" do
    Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, @forecast) end)
    assert {:ok, %{model: "wg", hours: [_ | _]}} = HTTPAdapter.forecast(52.36, 5.04)
  end

  test "station_reading/1 fetches and normalizes" do
    Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, @reading) end)
    assert {:ok, %{wind_kn: _}} = HTTPAdapter.station_reading(1234)
  end

  test "nearest_station/2 resolves nearest from the list endpoint" do
    Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, @stations) end)
    assert {:ok, result} = HTTPAdapter.nearest_station(52.36, 5.04)
    # With the real fixture this is either a nearby station map or nil (>30km) — assert shape:
    case result do
      nil -> :ok
      %{id: id, name: name, distance_km: d} ->
        assert is_integer(id) and is_binary(name) and is_number(d)
    end
  end

  test "windguru 500 becomes an error tuple" do
    Req.Test.stub(HTTPAdapter, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    assert {:error, _} = HTTPAdapter.forecast(52.36, 5.04)
  end

  test "non-JSON garbage becomes an error tuple, not a crash" do
    Req.Test.stub(HTTPAdapter, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>") end)
    assert {:error, _} = HTTPAdapter.forecast(52.36, 5.04)
  end
end
```

- [ ] **Step 3: Run to verify failure, then implement**

Adjust URLs/params/login flow to `docs/windguru-api-notes.md`. Structure:

```elixir
# server/lib/stallalert/windguru/http_adapter.ex
defmodule Stallalert.Windguru.HTTPAdapter do
  @behaviour Stallalert.Windguru.Adapter
  alias Stallalert.Windguru.{ForecastParser, StationParser}
  alias Stallalert.Geo

  @base "https://www.windguru.cz/int/iapi.php"

  @impl true
  def forecast(lat, lon) do
    with {:ok, body} <- get(%{q: "forecast", lat: lat, lon: lon, id_model: "wg"}) do
      ForecastParser.parse(body)
    end
  end

  @impl true
  def station_reading(id) do
    with {:ok, body} <- get(%{q: "station_data_current", id_station: id}) do
      StationParser.parse_reading(body)
    end
  end

  @impl true
  def nearest_station(lat, lon) do
    with {:ok, body} <- get(%{q: "stations", lat: lat, lon: lon}),
         {:ok, stations} <- StationParser.parse_station_list(body) do
      case Geo.nearest(stations, {lat, lon}) do
        nil -> {:ok, nil}
        {s, d} -> {:ok, %{id: s.id, name: s.name, distance_km: Float.round(d, 1)}}
      end
    end
  end

  defp get(params) do
    opts = Application.get_env(:stallalert, :windguru_req_options, [])

    req =
      Req.new(
        [base_url: @base,
         params: params,
         headers: [referer: "https://www.windguru.cz/"],
         retry: false] ++ opts
      )

    case Req.get(req) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %Req.Response{status: 200}} -> {:error, :unexpected_format}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Add login/session handling only if the notes from Task 1 show it is required for these endpoints (if so: a `login/0` that POSTs credentials from `WG_USERNAME`/`WG_PASSWORD` env vars, keeps the cookie in `:persistent_term`, retries once on 401/403).

- [ ] **Step 4: Run tests to verify pass**

Run: `mix test`
Expected: PASS (all tasks so far).

- [ ] **Step 5: Commit**

```bash
git add server/lib server/test server/config
git commit -m "feat(server): windguru HTTP adapter behind Adapter behaviour"
```

---

### Task 6: Conditions cache + poller GenServer

**Files:**
- Create: `server/lib/stallalert/conditions.ex`
- Create: `server/test/support/fake_adapter.ex`
- Modify: `server/lib/stallalert/application.ex` (add `Stallalert.Conditions` child)
- Modify: `server/config/config.exs` + `server/config/test.exs` (adapter injection)
- Modify: `server/mix.exs` (add `elixirc_paths` for test support)
- Test: `server/test/stallalert/conditions_test.exs`

**Interfaces:**
- Consumes: `Stallalert.Windguru.Adapter` behaviour (Task 5).
- Produces: `Stallalert.Conditions.get(lat, lon) :: {:ok, %{generated_at: DateTime.t(), stale: boolean, forecast: map, station: map | nil}} | {:error, :no_data}` — this is what the endpoint (Task 7) serializes. `station` is `%{id, name, distance_km, reading: %{time, wind_kn, gust_kn, dir_deg}}` or nil.

- [ ] **Step 1: Add adapter injection and test support path**

```elixir
# in server/config/config.exs, add:
config :stallalert, windguru_adapter: Stallalert.Windguru.HTTPAdapter
# in server/config/test.exs, add:
config :stallalert, windguru_adapter: Stallalert.FakeAdapter
```

```elixir
# in server/mix.exs, inside project/0:
elixirc_paths: elixirc_paths(Mix.env()),
# and add:
defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]
```

```elixir
# server/test/support/fake_adapter.ex
defmodule Stallalert.FakeAdapter do
  @behaviour Stallalert.Windguru.Adapter
  # Test process registers responses; defaults are healthy values.
  def set(key, value), do: :persistent_term.put({__MODULE__, key}, value)
  defp get_resp(key, default), do: :persistent_term.get({__MODULE__, key}, default)

  @impl true
  def forecast(_lat, _lon) do
    get_resp(:forecast, {:ok, %{model: "wg", init_time: ~U[2026-07-06 06:00:00Z],
      hours: [%{time: ~U[2026-07-06 10:00:00Z], wind_kn: 14.0, gust_kn: 21.0, dir_deg: 225.0}]}})
  end

  @impl true
  def nearest_station(_lat, _lon) do
    get_resp(:nearest_station, {:ok, %{id: 1, name: "TestStn", distance_km: 1.2}})
  end

  @impl true
  def station_reading(_id) do
    get_resp(:station_reading, {:ok, %{time: ~U[2026-07-06 09:55:00Z], wind_kn: 15.5, gust_kn: 20.1, dir_deg: 230.0}})
  end
end
```

- [ ] **Step 2: Write failing Conditions tests**

```elixir
# server/test/stallalert/conditions_test.exs
defmodule Stallalert.ConditionsTest do
  use ExUnit.Case  # not async: uses persistent_term-backed fake
  alias Stallalert.{Conditions, FakeAdapter}

  setup do
    FakeAdapter.set(:forecast, {:ok, %{model: "wg", init_time: ~U[2026-07-06 06:00:00Z],
      hours: [%{time: ~U[2026-07-06 10:00:00Z], wind_kn: 14.0, gust_kn: 21.0, dir_deg: 225.0}]}})
    FakeAdapter.set(:nearest_station, {:ok, %{id: 1, name: "TestStn", distance_km: 1.2}})
    FakeAdapter.set(:station_reading, {:ok, %{time: ~U[2026-07-06 09:55:00Z], wind_kn: 15.5, gust_kn: 20.1, dir_deg: 230.0}})
    pid = start_supervised!({Conditions, name: nil, refresh: false})
    {:ok, pid: pid}
  end

  test "first get fetches and returns fresh combined data", %{pid: pid} do
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    assert c.stale == false
    assert c.forecast.model == "wg"
    assert c.station.name == "TestStn"
    assert c.station.reading.wind_kn == 15.5
  end

  test "fetch failure with an existing cache serves stale data", %{pid: pid} do
    assert {:ok, _} = Conditions.get(pid, 52.36, 5.04)
    FakeAdapter.set(:forecast, {:error, :boom})
    FakeAdapter.set(:station_reading, {:error, :boom})
    send(pid, :refresh)                       # force a refresh tick that fails
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    assert c.forecast.model == "wg"           # last good data still served
  end

  test "no cache and failing fetch returns no_data", %{pid: pid} do
    FakeAdapter.set(:forecast, {:error, :boom})
    assert {:error, :no_data} = Conditions.get(pid, 52.36, 5.04)
  end

  test "no station within range yields station: nil", %{pid: pid} do
    FakeAdapter.set(:nearest_station, {:ok, nil})
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    assert c.station == nil
  end
end
```

- [ ] **Step 3: Run to verify failure, then implement Conditions**

```elixir
# server/lib/stallalert/conditions.ex
defmodule Stallalert.Conditions do
  @moduledoc """
  Caches normalized windguru data for the last requested position and
  refreshes it in the background (forecast 15 min, station 5 min).
  """
  use GenServer

  @forecast_ttl_ms 15 * 60 * 1000
  @station_ttl_ms 5 * 60 * 1000
  @grace_ms 10 * 60 * 1000

  # Client

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def get(server \\ __MODULE__, lat, lon), do: GenServer.call(server, {:get, lat, lon}, 15_000)

  # Server

  @impl true
  def init(opts) do
    refresh? = Keyword.get(opts, :refresh, true)
    if refresh?, do: Process.send_after(self(), :refresh, @station_ttl_ms)
    {:ok, %{pos: nil, forecast: nil, station: nil, refresh?: refresh?}}
  end

  @impl true
  def handle_call({:get, lat, lon}, _from, state) do
    state = %{state | pos: {lat, lon}}
    state = maybe_refresh(state, now_ms())

    case build_payload(state) do
      nil -> {:reply, {:error, :no_data}, state}
      payload -> {:reply, {:ok, payload}, state}
    end
  end

  @impl true
  def handle_info(:refresh, %{pos: nil} = state) do
    reschedule(state)
    {:noreply, state}
  end

  def handle_info(:refresh, state) do
    state = maybe_refresh(state, now_ms())
    reschedule(state)
    {:noreply, state}
  end

  defp reschedule(%{refresh?: true}), do: Process.send_after(self(), :refresh, @station_ttl_ms)
  defp reschedule(_), do: :ok

  defp maybe_refresh(%{pos: {lat, lon}} = state, now) do
    adapter = Application.fetch_env!(:stallalert, :windguru_adapter)

    forecast =
      refresh_entry(state.forecast, @forecast_ttl_ms, now, fn -> adapter.forecast(lat, lon) end)

    station =
      refresh_entry(state.station, @station_ttl_ms, now, fn ->
        case adapter.nearest_station(lat, lon) do
          {:ok, nil} -> {:ok, nil}
          {:ok, info} ->
            case adapter.station_reading(info.id) do
              {:ok, reading} -> {:ok, Map.put(info, :reading, reading)}
              {:error, _} = e -> e
            end
          {:error, _} = e -> e
        end
      end)

    %{state | forecast: forecast, station: station}
  end

  # entry: %{data: term, fetched_at: ms} | nil
  defp refresh_entry(entry, ttl, now, fetch_fun) do
    fresh? = entry != nil and now - entry.fetched_at < ttl

    if fresh? do
      entry
    else
      case fetch_fun.() do
        {:ok, data} -> %{data: data, fetched_at: now}
        {:error, _} -> entry
      end
    end
  end

  defp build_payload(%{forecast: nil}), do: nil

  defp build_payload(state) do
    now = now_ms()
    stale? = now - state.forecast.fetched_at > @forecast_ttl_ms + @grace_ms

    %{
      generated_at: DateTime.utc_now(),
      stale: stale?,
      forecast: state.forecast.data,
      station: state.station && state.station.data
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
```

Add to `application.ex` children (before Bandit): `Stallalert.Conditions,`

- [ ] **Step 4: Run tests to verify pass**

Run: `mix test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server
git commit -m "feat(server): conditions cache genserver with background refresh"
```

---

### Task 7: Authenticated /v1/conditions endpoint

**Files:**
- Create: `server/lib/stallalert/auth.ex`
- Modify: `server/lib/stallalert/router.ex`
- Modify: `server/config/test.exs` (test token)
- Test: `server/test/stallalert/router_test.exs` (extend)

**Interfaces:**
- Consumes: `Stallalert.Conditions.get/3` (Task 6).
- Produces: the HTTP API exactly as in the contract at the top of this plan. Forecast hours are trimmed to the first step at/after `now - 1h` through the following 12 steps.

- [ ] **Step 1: Extend router tests (failing)**

Add to `server/test/stallalert/router_test.exs` (make the module `async: false`, add `@token "test-token"`):

```elixir
  describe "GET /v1/conditions" do
    test "401 without bearer token" do
      conn = conn(:get, "/v1/conditions?lat=52.36&lon=5.04") |> Stallalert.Router.call(@opts)
      assert conn.status == 401
    end

    test "422 with missing or non-numeric lat/lon" do
      for qs <- ["", "lat=52.36", "lat=abc&lon=5.04"] do
        conn =
          conn(:get, "/v1/conditions?" <> qs)
          |> put_req_header("authorization", "Bearer test-token")
          |> Stallalert.Router.call(@opts)
        assert conn.status == 422
      end
    end

    test "200 with normalized payload" do
      conn =
        conn(:get, "/v1/conditions?lat=52.36&lon=5.04")
        |> put_req_header("authorization", "Bearer test-token")
        |> Stallalert.Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert %{"generated_at" => _, "stale" => false, "forecast" => f, "station" => s} = body
      assert %{"model" => "wg", "init_time" => _, "hours" => [h | _]} = f
      assert %{"time" => _, "wind_kn" => _, "gust_kn" => _, "dir_deg" => _} = h
      assert %{"id" => _, "name" => _, "distance_km" => _, "reading" => _} = s
    end
  end
```

In `server/config/test.exs` add: `config :stallalert, api_token: "test-token"`. These tests rely on the globally-named `Stallalert.Conditions` started by the app with the `FakeAdapter` — ensure `FakeAdapter` defaults (no `set/2` calls) return healthy data so the 200 test is deterministic.

- [ ] **Step 2: Run to verify failure, then implement auth plug and route**

```elixir
# server/lib/stallalert/auth.ex
defmodule Stallalert.Auth do
  import Plug.Conn

  def init(opts), do: opts

  # Health stays open; everything else needs the bearer token.
  def call(%Plug.Conn{path_info: ["v1", "health"]} = conn, _opts), do: conn

  def call(conn, _opts) do
    expected = Application.fetch_env!(:stallalert, :api_token)

    case get_req_header(conn, "authorization") do
      ["Bearer " <> ^expected] -> conn
      _ -> conn |> send_resp(401, "unauthorized") |> halt()
    end
  end
end
```

In `router.ex`, add plugs and the route:

```elixir
  plug Stallalert.Auth
  plug :match
  plug :dispatch

  get "/v1/conditions" do
    conn = fetch_query_params(conn)

    with {lat, ""} <- Float.parse(conn.query_params["lat"] || ""),
         {lon, ""} <- Float.parse(conn.query_params["lon"] || "") do
      case Stallalert.Conditions.get(lat, lon) do
        {:ok, payload} -> json(conn, 200, serialize(payload))
        {:error, :no_data} -> json(conn, 503, %{error: "no data available yet"})
      end
    else
      _ -> json(conn, 422, %{error: "lat and lon are required floats"})
    end
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp serialize(payload) do
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

    hours =
      payload.forecast.hours
      |> Enum.filter(&(DateTime.compare(&1.time, cutoff) != :lt))
      |> Enum.take(12)

    %{
      generated_at: payload.generated_at,
      stale: payload.stale,
      forecast: %{payload.forecast | hours: hours},
      station: payload.station
    }
  end
```

(`Jason` encodes `DateTime` as ISO-8601 automatically. `Stallalert.Auth` must be plugged **before** `:match`.)

- [ ] **Step 3: Run tests to verify pass**

Run: `mix test`
Expected: PASS.

- [ ] **Step 4: Configure the real token for prod**

Create `server/config/runtime.exs`:

```elixir
import Config

if config_env() == :prod do
  config :stallalert,
    api_token: System.fetch_env!("API_TOKEN")
end
```

- [ ] **Step 5: Commit**

```bash
git add server
git commit -m "feat(server): authenticated /v1/conditions endpoint"
```

---

### Task 8: Opt-in live integration test

**Files:**
- Create: `server/test/live/windguru_live_test.exs`
- Modify: `server/test/test_helper.exs`

**Interfaces:**
- Consumes: `Stallalert.Windguru.HTTPAdapter` (Task 5) against the real Windguru API.

- [ ] **Step 1: Exclude :live by default**

```elixir
# server/test/test_helper.exs
ExUnit.start(exclude: [:live])
```

- [ ] **Step 2: Write the live test**

```elixir
# server/test/live/windguru_live_test.exs
defmodule Stallalert.WindguruLiveTest do
  use ExUnit.Case
  @moduletag :live
  # Run with: WG_USERNAME=... WG_PASSWORD=... mix test --only live
  # Uses the real HTTPAdapter (test config's Req.Test plug must be bypassed):
  setup do
    prev = Application.get_env(:stallalert, :windguru_req_options)
    Application.put_env(:stallalert, :windguru_req_options, [])
    on_exit(fn -> Application.put_env(:stallalert, :windguru_req_options, prev) end)
  end

  test "fetches a real forecast for a real position" do
    assert {:ok, %{hours: hours}} = Stallalert.Windguru.HTTPAdapter.forecast(52.36, 5.04)
    assert length(hours) >= 12
  end
end
```

- [ ] **Step 3: Verify default suite still passes and live test runs when opted in**

Run: `mix test` → PASS, live test shown as excluded.
Run: `WG_USERNAME=... WG_PASSWORD=... mix test --only live` → PASS (requires network + valid creds).

- [ ] **Step 4: Commit**

```bash
git add server/test
git commit -m "test(server): opt-in live windguru integration test"
```

---

### Task 9: Release, Dockerfile, and deployment docs

**Files:**
- Create: `server/Dockerfile`
- Create: `server/.dockerignore`
- Create: `docs/deploy.md`

**Interfaces:**
- Consumes: the complete app (Tasks 2–8).
- Produces: a Docker image `stallalert-server` and written deployment steps for the user's fixed-IP host (Caddy terminating TLS on the user's domain).

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
# server/Dockerfile
FROM hexpm/elixir:1.17.3-erlang-27.1-alpine-3.20 AS build
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile
COPY config config
COPY lib lib
RUN mix release

FROM alpine:3.20
RUN apk add --no-cache libstdc++ openssl ncurses-libs
WORKDIR /app
COPY --from=build /app/_build/prod/rel/stallalert ./
ENV PORT=4000
EXPOSE 4000
CMD ["bin/stallalert", "start"]
```

```
# server/.dockerignore
_build
deps
test
.git
```

- [ ] **Step 2: Build and smoke-test the container**

```bash
cd server
docker build -t stallalert-server .
docker run -d --rm -p 4000:4000 \
  -e API_TOKEN=localtest -e WG_USERNAME=x -e WG_PASSWORD=x \
  --name stallalert-smoke stallalert-server
curl -s localhost:4000/v1/health          # expect {"status":"ok"}
curl -s -o /dev/null -w "%{http_code}" localhost:4000/v1/conditions?lat=1\&lon=1  # expect 401
docker stop stallalert-smoke
```

- [ ] **Step 3: Write docs/deploy.md**

```markdown
# Deploying the StallAlert server

## Prerequisites
- A host with a fixed IP, Docker, and ports 80/443 open.
- A DNS A record: stallalert.<yourdomain> -> <fixed IP>.

## Run the service
docker run -d --restart unless-stopped --name stallalert \
  -p 127.0.0.1:4000:4000 \
  -e API_TOKEN="$(openssl rand -hex 32)" \
  -e WG_USERNAME=... -e WG_PASSWORD=... \
  stallalert-server
Record the API_TOKEN — the watch app needs it.

## TLS via Caddy (automatic Let's Encrypt)
/etc/caddy/Caddyfile:
    stallalert.<yourdomain> {
        reverse_proxy 127.0.0.1:4000
    }
Then: systemctl reload caddy

## Verify from outside
curl https://stallalert.<yourdomain>/v1/health          -> {"status":"ok"}
curl -H "Authorization: Bearer $API_TOKEN" \
  "https://stallalert.<yourdomain>/v1/conditions?lat=52.36&lon=5.04"

## Updating (e.g. after a Windguru format change)
Rebuild the image, docker stop + rerun. The watch app needs no update.
```

- [ ] **Step 4: Commit**

```bash
git add server/Dockerfile server/.dockerignore docs/deploy.md
git commit -m "feat(server): docker release and deployment docs"
```

---

### Task 10: Micro-API forecast fallback in the adapter

**Files:**
- Create: `server/lib/stallalert/windguru/micro_parser.ex`
- Modify: `server/lib/stallalert/windguru/http_adapter.ex` (forecast/2 falls back to micro)
- Test: `server/test/stallalert/windguru/micro_parser_test.exs`

**Interfaces:**
- Consumes: `server/test/fixtures/windguru/micro_forecast.txt` (Task 1); env vars `WG_USERNAME`, `WG_MICRO_PASSWORD`.
- Produces: `Stallalert.Windguru.MicroParser.parse(text) :: {:ok, forecast} | {:error, :unexpected_format}` returning the SAME normalized forecast map as `ForecastParser` (Task 3), with `model: "wg-micro"`.

- [ ] **Step 1: Write the failing parser test against the captured text fixture**

```elixir
# server/test/stallalert/windguru/micro_parser_test.exs
defmodule Stallalert.Windguru.MicroParserTest do
  use ExUnit.Case, async: true
  alias Stallalert.Windguru.MicroParser

  @fixture File.read!("test/fixtures/windguru/micro_forecast.txt")

  test "parses micro text into the normalized timeline" do
    assert {:ok, f} = MicroParser.parse(@fixture)
    assert f.model == "wg-micro"
    assert [%{time: %DateTime{}, wind_kn: w, gust_kn: g, dir_deg: d} | _] = f.hours
    assert is_number(w) and is_number(g) and is_number(d)
  end

  test "rejects garbage" do
    assert {:error, :unexpected_format} = MicroParser.parse("<html>nope</html>")
    assert {:error, :unexpected_format} = MicroParser.parse("")
  end
end
```

Add 2–3 exact-value assertions from the real fixture once captured.

- [ ] **Step 2: Run to verify failure, then implement**

The micro format is line-oriented text (one row per timestep: date/hour, wind, gusts, direction — exact columns per the captured fixture and `docs/windguru-api-notes.md`). Implement line-by-line parsing with `Regex`/`String.split`, converting cardinal directions to degrees if the fixture uses them (N=0, NE=45, … NW=315, 16-point rose at 22.5° steps). Return `{:error, :unexpected_format}` unless at least 3 timesteps parse.

- [ ] **Step 3: Wire the fallback into the adapter**

In `http_adapter.ex`, change `forecast/2`:

```elixir
  @impl true
  def forecast(lat, lon) do
    with {:ok, body} <- get(%{q: "forecast", lat: lat, lon: lon, id_model: "wg"}),
         {:ok, forecast} <- ForecastParser.parse(body) do
      {:ok, forecast}
    else
      {:error, _} -> micro_forecast(lat, lon)
    end
  end

  defp micro_forecast(lat, lon) do
    opts = Application.get_env(:stallalert, :windguru_req_options, [])

    params = %{
      lat: lat, lon: lon, m: "wg",
      u: System.fetch_env!("WG_USERNAME"),
      p: System.fetch_env!("WG_MICRO_PASSWORD")
    }

    req = Req.new([url: "https://micro.windguru.cz/", params: params, retry: false] ++ opts)

    case Req.get(req) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        Stallalert.Windguru.MicroParser.parse(body)
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
```

Add an adapter test: stub the iapi call to 500 and the micro call to return the text fixture (`Req.Test.stub` dispatching on `conn.host`), assert `forecast/2` returns `{:ok, %{model: "wg-micro"}}`.

- [ ] **Step 4: Run tests to verify pass, commit**

Run: `mix test` → PASS.

```bash
git add server
git commit -m "feat(server): micro-API text fallback for forecasts"
```
