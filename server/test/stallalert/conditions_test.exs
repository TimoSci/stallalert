defmodule Stallalert.ConditionsTest do
  # not async: uses persistent_term-backed fake
  use ExUnit.Case
  alias Stallalert.{Conditions, FakeAdapter}

  setup do
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

  test "fetch failure with an existing cache serves stale data", %{pid: pid} do
    assert {:ok, _} = Conditions.get(pid, 52.36, 5.04)
    FakeAdapter.set(:forecast, {:error, :boom})
    FakeAdapter.set(:station_reading, {:error, :boom})
    # force a refresh tick that fails
    send(pid, :refresh)
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    # last good data still served
    assert c.forecast.model == "wg"
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
