defmodule Stallalert.WindguruLiveTest do
  @moduledoc """
  Opt-in integration test that hits the *real* Windguru endpoints (no
  `Req.Test` stub). Excluded by default (see `test/test_helper.exs`).

  Makes 3 live HTTP requests when run: `forecast/2`, `station_reading/1`,
  and `nearest_station/2` against `Stallalert.Windguru.HTTPAdapter`.

  Coordinates are the user's real region (Mallorca): lat 39.92, lon 3.09.
  Station 4048 is a real, nearby station used for both `station_reading/1`
  and to sanity-check `nearest_station/2`'s distance.

  ## Running

  `forecast/2` requires a fresh `WG_COOKIE` (an opaque, manually-refreshed
  browser session cookie — see the moduledoc on `Stallalert.Windguru.HTTPAdapter`
  for the cookie strategy). `server/.env.capture` defines it as a shell
  variable (git-ignored, never commit it). Export it and run:

      cd server && set -a && source .env.capture && set +a && mix test --only live

  If `WG_USERNAME`/`WG_PASSWORD`/`WG_MICRO_PASSWORD` (from `.env.local`) are
  *also* exported, a cookie failure on the `forecast/2` iapi leg may be
  masked by the adapter's micro-API fallback (see `HTTPAdapter.forecast/2`
  moduledoc) — that fallback succeeding is still treated as a PASS here (see
  the forecast test below for how that's asserted), since the goal is "did
  the public contract of `forecast/2` hold up against the real network",
  not "did the iapi leg specifically succeed".

  Never print the sourced env values (this file must not log secrets).
  """

  use ExUnit.Case, async: false

  alias Stallalert.Windguru.HTTPAdapter

  @moduletag :live
  @moduletag timeout: 30_000

  # User's real region (Mallorca).
  @lat 39.92
  @lon 3.09
  # Real, nearby station used for capture/discovery (see docs/windguru-api-notes.md).
  @station_id 4048
  @max_nearest_km 30

  setup do
    HTTPAdapter.clear_station_cache()
    prev = Application.get_env(:stallalert, :windguru_req_options)
    Application.put_env(:stallalert, :windguru_req_options, [])

    on_exit(fn ->
      Application.put_env(:stallalert, :windguru_req_options, prev)
      HTTPAdapter.clear_station_cache()
    end)

    :ok
  end

  test "forecast/2 fetches a real forecast for a real position" do
    case HTTPAdapter.forecast(@lat, @lon) do
      {:error, reason} when reason in [:cookie_expired, :auth_required] ->
        flunk("""
        forecast/2 returned #{inspect(reason)} — the WG_COOKIE session cookie \
        is expired or unset (and the micro fallback wasn't configured/reachable \
        either). Refresh WG_COOKIE per docs/deploy.md and re-run:
          cd server && set -a && source .env.capture && set +a && mix test --only live
        """)

      {:ok, %{model: "gfs-micro"} = result} ->
        # The iapi leg hit an error (possibly the cookie expiring) and
        # forecast/2 fell back to the micro API. Per the adapter's fallback
        # contract this is a legitimate success of the public forecast/2
        # call, so it's a PASS — but flag it loudly since it means the
        # cookie-gated iapi path was NOT actually exercised by this run.
        IO.puts(
          "\n[live] forecast/2 fell back to micro.windguru.cz (model=gfs-micro) — " <>
            "the iapi/cookie-gated path was NOT exercised this run.\n"
        )

        assert %{hours: [_ | _]} = result

      {:ok, %{hours: hours} = result} ->
        refute result[:model] == "gfs-micro"
        assert length(hours) >= 12
    end
  end

  test "station_reading/1 fetches a real station reading" do
    assert {:ok, %{wind_kn: _, time: %DateTime{}}} = HTTPAdapter.station_reading(@station_id)
  end

  test "nearest_station/2 resolves a real nearby station" do
    assert {:ok, result} = HTTPAdapter.nearest_station(@lat, @lon)

    case result do
      nil ->
        flunk(
          "nearest_station/2 returned {:ok, nil} — expected a station within " <>
            "#{@max_nearest_km}km of (#{@lat}, #{@lon}), since station #{@station_id} " <>
            "is known to be nearby."
        )

      %{id: _id, name: _name, distance_km: d} ->
        assert d <= @max_nearest_km
    end
  end
end
