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

  # The forecast leg is fetched by a background `Task`; a fresh cache never
  # blocks `get/4` on it (see Conditions' moduledoc). This polls a bounded
  # number of times, giving the task's completion message time to reach and
  # be processed by the GenServer, instead of asserting on wall-clock timing.
  #
  # `pred` defaults to "any successful reply" -- but note that a switched
  # descriptor (model/position) can legitimately keep replying `{:ok, _}`
  # with the *old* last-good entry while the new fetch is still in flight
  # (that's the whole point of the async design), so callers proving a
  # switch actually landed must pass a `pred` that checks the new content,
  # not just tuple shape.
  defp eventually_ok(fun, pred \\ fn _ -> true end, tries \\ 200) do
    case fun.() do
      {:ok, val} = ok ->
        if pred.(val) do
          ok
        else
          retry_eventually(fun, pred, tries)
        end

      other ->
        retry_eventually(fun, pred, tries, other)
    end
  end

  defp retry_eventually(fun, pred, tries, last \\ nil)
  defp retry_eventually(_fun, _pred, 0, last), do: last

  defp retry_eventually(fun, pred, tries, _last) do
    Process.sleep(5)
    eventually_ok(fun, pred, tries - 1)
  end

  test "first get on an empty cache returns no_data and kicks off a background fetch", %{
    pid: pid
  } do
    assert {:error, :no_data} = Conditions.get(pid, 52.36, 5.04)
  end

  test "a subsequent get after the background fetch completes serves the blend", %{pid: pid} do
    assert {:error, :no_data} = Conditions.get(pid, 52.36, 5.04)
    assert {:ok, c} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04) end)
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

    assert {:ok, _} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04) end)
    FakeAdapter.set(:forecast, {:error, :boom})
    FakeAdapter.set(:nearest_station, {:error, :boom})
    FakeAdapter.set(:station_reading, {:error, :boom})
    # TTL 0 forces a real re-fetch on this get; the fetch fails; last good data must survive.
    # (The forecast re-fetch is kicked off async and its failure is silently
    # dropped -- this call's *own* reply is always the pre-existing entry.)
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    assert c.forecast.model == "wg"
    assert c.station.name == "TestStn"
  end

  test "no cache and a persistently failing fetch never produces data", %{pid: pid} do
    FakeAdapter.set(:forecast, {:error, :boom})
    assert {:error, :no_data} = Conditions.get(pid, 52.36, 5.04)
    # Give the (failing) background fetch a chance to complete; still no_data.
    Process.sleep(20)
    assert {:error, :no_data} = Conditions.get(pid, 52.36, 5.04)
  end

  @tag :capture_log
  test "a crashed forecast task clears the in-flight gate and the next request retries", %{
    pid: pid
  } do
    FakeAdapter.set(:forecast, :raise)

    # First get triggers async task that will crash
    assert {:error, :no_data} = Conditions.get(pid, 52.36, 5.04)

    # Restore healthy forecast response; the crash will clear the in-flight
    # gate, allowing the next get to start a fresh fetch. Without the fix,
    # the gate remains set to the dead task's ref, and retries are stuck.
    FakeAdapter.set(
      :forecast,
      {:ok,
       %{
         model: "wg",
         init_time: ~U[2026-07-06 06:00:00Z],
         hours: [%{time: ~U[2026-07-06 10:00:00Z], wind_kn: 14.0, gust_kn: 21.0, dir_deg: 225.0}]
       }}
    )

    # Eventually the new fetch completes (if gate was properly cleared)
    # by the :DOWN handler.
    assert {:ok, c} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04) end)
    assert c.forecast.model == "wg"
  end

  test "no station within range yields station: nil", %{pid: pid} do
    FakeAdapter.set(:nearest_station, {:ok, nil})
    assert {:ok, c} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04) end)
    assert c.station == nil
  end

  test "serves stale: true when forecast cannot be refreshed past ttl+grace" do
    pid =
      start_supervised!(
        {Conditions, name: nil, refresh: false, forecast_ttl_ms: 0, grace_ms: 0},
        id: :forecast_stale
      )

    assert {:ok, _} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04) end)
    FakeAdapter.set(:forecast, {:error, :boom})
    Process.sleep(10)
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    assert c.stale == true
    assert c.forecast.model == "wg"
  end

  test "moving > 2km within TTL invalidates the station cache and re-resolves", %{pid: pid} do
    assert {:ok, c} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04) end)
    assert c.station.name == "TestStn"

    FakeAdapter.set(:nearest_station, {:ok, %{id: 2, name: "OtherStn", distance_km: 0.8}})

    # ~0.05 deg lat ~= 5.5 km away (0.01 deg lat ~= 1.11 km), well within TTL.
    assert {:ok, c} = Conditions.get(pid, 52.36 + 0.05, 5.04)
    assert c.station.name == "OtherStn"
  end

  test "moving < 2km within TTL keeps serving the cached position's data", %{pid: pid} do
    assert {:ok, c} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04) end)
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

    assert {:ok, _} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04) end)
    FakeAdapter.set(:nearest_station, {:error, :boom})
    FakeAdapter.set(:station_reading, {:error, :boom})
    Process.sleep(10)
    assert {:ok, c} = Conditions.get(pid, 52.36, 5.04)
    assert c.stale == true
    assert c.station.name == "TestStn"
  end

  test "override station_id is honored and marked manual", %{pid: pid} do
    assert {:ok, c} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04, station_id: 77) end)
    assert c.station.id == 77
    assert c.station.source == "manual"
  end

  test "unknown override falls back to auto-nearest", %{pid: pid} do
    Stallalert.FakeAdapter.set(:station_by_id, {:ok, nil})

    assert {:ok, c} =
             eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04, station_id: 424_242) end)

    assert c.station.name == "TestStn"
    assert c.station.source == "auto"
  end

  test "no override is auto", %{pid: pid} do
    assert {:ok, c} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04) end)
    assert c.station.source == "auto"
  end

  test "switching override invalidates the cached station entry immediately", %{pid: pid} do
    assert {:ok, c1} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04, station_id: 1) end)
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
    assert {:ok, c} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04) end)
    assert [%{id: _, name: _, distance_km: _} | _] = c.nearby_stations
  end

  test "nearby_stations degrades to empty list on adapter error", %{pid: pid} do
    Stallalert.FakeAdapter.set(:stations_near, {:error, :boom})
    assert {:ok, c} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04) end)
    assert c.nearby_stations == []
  end

  test "repeated identical rejected override is cache-stable within TTL", %{pid: pid} do
    Stallalert.FakeAdapter.set(:station_by_id, {:ok, nil})

    assert {:ok, c1} =
             eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04, station_id: 424_242) end)

    assert c1.station.source == "auto"
    assert c1.station.reading.wind_kn == 15.5
    # change what a REFETCH would return; a cache-stable repeat must NOT see it
    Stallalert.FakeAdapter.set(
      :station_reading,
      {:ok, %{time: ~U[2026-07-08 12:00:00Z], wind_kn: 99.9, gust_kn: 99.9, dir_deg: 1.0}}
    )

    assert {:ok, c2} = Conditions.get(pid, 52.36, 5.04, station_id: 424_242)
    # cached — would be 99.9 if thrashing
    assert c2.station.reading.wind_kn == 15.5
    # control: switching to a VALID override must refetch and see the new value
    # reset station_by_id to allow 77 to resolve
    :persistent_term.erase({Stallalert.FakeAdapter, :station_by_id})
    assert {:ok, c3} = Conditions.get(pid, 52.36, 5.04, station_id: 77)
    assert c3.station.id == 77
    assert c3.station.reading.wind_kn == 99.9
  end

  describe "model selection" do
    # The outer setup pins :forecast to a static "wg" fixture (for the tests
    # above, which don't care about model). These tests need FakeAdapter's
    # *default* forecast/3 behavior instead, which echoes the requested
    # model verbatim -- so undo that pin here.
    setup do
      :persistent_term.erase({Stallalert.FakeAdapter, :forecast})
      :ok
    end

    test "default (no :model opt) requests and echoes wg", %{pid: pid} do
      assert {:ok, c} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04) end)
      assert c.forecast.model == "wg"
      assert c.requested_model == "wg"
    end

    test "an explicit model is honored and echoed", %{pid: pid} do
      assert {:ok, c} =
               eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04, model: "52") end)

      assert c.forecast.model == "52"
      assert c.requested_model == "52"
    end

    test "switching model invalidates the forecast cache and refetches", %{pid: pid} do
      assert {:ok, c1} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04, model: "52") end)
      assert c1.forecast.model == "52"

      # Within TTL, different model: the refresh is async, so the reply
      # right after the switch can (legitimately) still be the OLD cached
      # entry ("52") while the new fetch is in flight -- poll until the
      # new model's data has actually landed.
      assert {:ok, c2} =
               eventually_ok(
                 fn -> Conditions.get(pid, 52.36, 5.04, model: "104") end,
                 fn c -> c.forecast.model == "104" end
               )

      assert c2.forecast.model == "104"
      assert c2.requested_model == "104"
    end

    test "an identical repeat is cache-stable within TTL (no refetch)", %{pid: pid} do
      assert {:ok, c1} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04, model: "52") end)
      assert c1.forecast.model == "52"

      calls_before = FakeAdapter.forecast_calls()
      assert {:ok, c2} = Conditions.get(pid, 52.36, 5.04, model: "52")
      assert c2.forecast.model == "52"
      assert FakeAdapter.forecast_calls() == calls_before
    end

    test "in-flight refreshes for the same target are deduplicated", %{pid: pid} do
      calls_before = FakeAdapter.forecast_calls()
      # Two rapid gets against a cold cache with the same descriptor: the
      # second must not start a second concurrent fetch.
      assert {:error, :no_data} = Conditions.get(pid, 52.36, 5.04, model: "52")
      assert {:error, :no_data} = Conditions.get(pid, 52.36, 5.04, model: "52")

      assert {:ok, _} = eventually_ok(fn -> Conditions.get(pid, 52.36, 5.04, model: "52") end)
      assert FakeAdapter.forecast_calls() - calls_before == 1
    end

    test "a stale in-flight completion (position changed mid-flight) is discarded", %{pid: pid} do
      # Pin down "fetch A has started but not finished" deterministically
      # (see FakeAdapter.forecast/3's :block mode) instead of racing real
      # task scheduling.
      FakeAdapter.set(:forecast, {:block, self()})

      assert {:error, :no_data} = Conditions.get(pid, 52.36, 5.04)
      assert_receive {:fake_adapter_forecast_started, task_a_pid, ref_a, :wg}, 500

      # Move far away (> 2km, well past @move_invalidate_km) while A is
      # still blocked in flight: this must start a NEW fetch (B) for the
      # new position rather than reuse A's in-flight tracking.
      distinctive_b = distinctive_forecast("distinctive-B")
      FakeAdapter.set(:forecast, {:ok, distinctive_b})

      assert {:error, :no_data} = Conditions.get(pid, 52.36 + 0.05, 5.04)

      assert {:ok, c} =
               eventually_ok(fn -> Conditions.get(pid, 52.36 + 0.05, 5.04) end)

      assert c.forecast.model == "distinctive-B"

      # Now release A with a distinguishable payload. Its ref no longer
      # matches the current (already-cleared) forecast_inflight, so it must
      # be discarded rather than clobbering B's already-applied entry.
      distinctive_a = distinctive_forecast("distinctive-A")
      send(task_a_pid, {:fake_adapter_forecast_release, ref_a, {:ok, distinctive_a}})
      Process.sleep(20)

      assert {:ok, c} = Conditions.get(pid, 52.36 + 0.05, 5.04)
      assert c.forecast.model == "distinctive-B"
    end
  end

  defp distinctive_forecast(tag) do
    now = DateTime.utc_now()

    %{
      model: tag,
      init_time: DateTime.add(now, -4 * 3600, :second),
      hours: [%{time: DateTime.add(now, 3600, :second), wind_kn: 1.0, gust_kn: 1.0, dir_deg: 1.0}]
    }
  end
end
