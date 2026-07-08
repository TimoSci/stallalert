defmodule Stallalert.ConditionsTest do
  # not async: uses persistent_term-backed fake
  use ExUnit.Case
  alias Stallalert.{Conditions, FakeAdapter}

  setup do
    FakeAdapter.reset()

    FakeAdapter.set(
      :forecast,
      {:ok,
       %{
         model: "wg",
         init_time: ~U[2026-07-06 06:00:00Z],
         hours: [%{time: ~U[2026-07-06 10:00:00Z], wind_kn: 14.0, gust_kn: 21.0, dir_deg: 225.0}]
       }}
    )

    FakeAdapter.set(:nearest_station, {:ok, %{id: 1, name: "TestStn", distance_km: 1.2}})

    FakeAdapter.set(
      :station_reading,
      {:ok, %{time: ~U[2026-07-06 09:55:00Z], wind_kn: 15.5, gust_kn: 20.1, dir_deg: 230.0}}
    )

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

  test "fetch failure with an existing cache serves last good data" do
    pid =
      start_supervised!(
        {Conditions, name: nil, refresh: false, forecast_ttl_ms: 0, station_ttl_ms: 0},
        id: :zero_ttl
      )

    assert {:ok, _} = Conditions.get(pid, 52.36, 5.04)
    FakeAdapter.set(:forecast, {:error, :boom})
    FakeAdapter.set(:nearest_station, {:error, :boom})
    FakeAdapter.set(:station_reading, {:error, :boom})
    # TTL 0 forces a real re-fetch on this get; the fetch fails; last good data must survive.
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    assert c.forecast.model == "wg"
    assert c.station.name == "TestStn"
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

  test "serves stale: true when forecast cannot be refreshed past ttl+grace" do
    pid =
      start_supervised!(
        {Conditions, name: nil, refresh: false, forecast_ttl_ms: 0, grace_ms: 0},
        id: :forecast_stale
      )

    assert {:ok, _} = Conditions.get(pid, 52.36, 5.04)
    FakeAdapter.set(:forecast, {:error, :boom})
    Process.sleep(10)
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    assert c.stale == true
    assert c.forecast.model == "wg"
  end

  test "moving > 2km within TTL invalidates the cache and re-resolves", %{pid: pid} do
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    assert c.station.name == "TestStn"

    FakeAdapter.set(:nearest_station, {:ok, %{id: 2, name: "OtherStn", distance_km: 0.8}})

    # ~0.05 deg lat ~= 5.5 km away (0.01 deg lat ~= 1.11 km), well within TTL.
    assert {:ok, c} = Conditions.get(pid, 52.36 + 0.05, 5.04)
    assert c.station.name == "OtherStn"
  end

  test "moving < 2km within TTL keeps serving the cached position's data", %{pid: pid} do
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    assert c.station.name == "TestStn"

    FakeAdapter.set(:nearest_station, {:ok, %{id: 2, name: "OtherStn", distance_km: 0.8}})

    # ~0.005 deg lat ~= 0.55 km away, under the 2km invalidation threshold.
    assert {:ok, c} = Conditions.get(pid, 52.36 + 0.005, 5.04)
    assert c.station.name == "TestStn"
  end

  test "serves stale: true when only the station reading is past its ttl+grace" do
    pid =
      start_supervised!(
        {Conditions, name: nil, refresh: false, station_ttl_ms: 0, grace_ms: 0},
        id: :station_stale
      )

    assert {:ok, _} = Conditions.get(pid, 52.36, 5.04)
    FakeAdapter.set(:nearest_station, {:error, :boom})
    FakeAdapter.set(:station_reading, {:error, :boom})
    Process.sleep(10)
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    assert c.stale == true
    assert c.station.name == "TestStn"
  end

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
end
