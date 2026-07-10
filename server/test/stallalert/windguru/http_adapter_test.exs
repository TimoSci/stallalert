defmodule Stallalert.Windguru.HTTPAdapterTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Stallalert.FakeAdapter
  alias Stallalert.Windguru.{BlendConfig, HTTPAdapter}

  @forecast_custom "test/fixtures/windguru/forecast_custom.json"
                   |> File.read!()
                   |> Jason.decode!()
  @forecast_m52 "test/fixtures/windguru/forecast_m52.json" |> File.read!() |> Jason.decode!()
  @forecast_m104 "test/fixtures/windguru/forecast_m104.json" |> File.read!() |> Jason.decode!()
  @reading "test/fixtures/windguru/station_current.json" |> File.read!() |> Jason.decode!()
  @stations "test/fixtures/windguru/stations_list.json" |> File.read!() |> Jason.decode!()
  @micro_forecast "test/fixtures/windguru/micro_forecast.txt" |> File.read!()
  @spot_config "test/fixtures/windguru/forecast_spot.json" |> File.read!() |> Jason.decode!()

  # The documented "outside grid" 404 body shape (docs/windguru-api-notes.md).
  @outside_grid_body Jason.encode!(%{
                       "return" => "error",
                       "message" => "Data not available! (outside grid)"
                     })

  setup do
    HTTPAdapter.clear_station_cache()
    HTTPAdapter.clear_forecast_cache()
    HTTPAdapter.clear_availability_cache()
    FakeAdapter.reset()
    BlendConfig.clear_cache()

    env_vars = ["WG_COOKIE", "WG_USERNAME", "WG_MICRO_PASSWORD"]
    originals = Map.new(env_vars, &{&1, System.get_env(&1)})
    Enum.each(env_vars, &System.delete_env/1)

    on_exit(fn ->
      HTTPAdapter.clear_station_cache()
      HTTPAdapter.clear_forecast_cache()
      HTTPAdapter.clear_availability_cache()
      BlendConfig.clear_cache()
      Application.delete_env(:stallalert, :windguru_spacing_test_hook)

      Enum.each(originals, fn
        {var, nil} -> System.delete_env(var)
        {var, val} -> System.put_env(var, val)
      end)
    end)

    :ok
  end

  # Drains every `{:spacing_applied, ms}` message currently in the mailbox
  # (see `HTTPAdapter`'s test-only spacing hook, armed via
  # `windguru_spacing_test_hook`), in receive order.
  defp collect_spacing_messages(acc \\ []) do
    receive do
      {:spacing_applied, ms} -> collect_spacing_messages([ms | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Seeds `BlendConfig.weights/0` (a global persistent_term-backed cache,
  # see BlendConfig's clear_cache/0 doc) with an exact constituent list for
  # a test, via a throwaway BlendConfig GenServer instance backed by
  # `FakeAdapter` (NOT `HTTPAdapter` — this doesn't touch the `Req.Test`
  # stub under test). `sync/1` waits for the seeding fetch to land.
  defp seed_constituents(constituents) do
    body = %{
      "tabs" => [
        %{
          "id_model" => 100,
          "id_model_wave" => 84,
          "id_model_arr" => Enum.map(constituents, &%{"id_model" => &1}),
          "blend" => %{"model_koef" => Map.new(constituents, &{Integer.to_string(&1), 1})}
        }
      ]
    }

    FakeAdapter.set(:spot_config, {:ok, body})
    pid = start_supervised!({BlendConfig, name: nil}, id: make_ref())
    sync(pid)
  end

  defp sync(pid), do: :sys.get_state(pid)

  defp stub_station_list_fixture do
    Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, @stations) end)
  end

  test "forecast/3 with an explicit model fetches and normalizes the custom lat/lon payload" do
    Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, @forecast_custom) end)
    assert {:ok, %{model: "GFS 13 km", hours: [_ | _]}} = HTTPAdapter.forecast(52.36, 5.04, 3)
  end

  test "forecast/3 decodes a JSON body even when the response has a non-JSON content-type" do
    System.put_env("WG_COOKIE", "langc=en; session=fake; login_md5=fake")

    Req.Test.stub(HTTPAdapter, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, File.read!("test/fixtures/windguru/forecast_custom.json"))
    end)

    assert {:ok, %{model: _, hours: [_ | _]}} = HTTPAdapter.forecast(52.36, 5.04, 3)
  end

  test "station_reading/1 fetches and normalizes" do
    Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, @reading) end)
    assert {:ok, %{wind_kn: _}} = HTTPAdapter.station_reading(1234)
  end

  test "spot_config/1 fetches and returns the raw forecast_spot JSON" do
    Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, @spot_config) end)
    assert {:ok, %{"tabs" => [_ | _]}} = HTTPAdapter.spot_config(1_189_718)
  end

  test "spot_config/1 sends the cookie header when WG_COOKIE is set" do
    System.put_env("WG_COOKIE", "langc=en; session=fake; login_md5=fake")
    test_pid = self()

    Req.Test.stub(HTTPAdapter, fn conn ->
      cookie = Plug.Conn.get_req_header(conn, "cookie")
      send(test_pid, {:cookie_header, cookie})
      Req.Test.json(conn, @spot_config)
    end)

    assert {:ok, _} = HTTPAdapter.spot_config(1_189_718)
    assert_received {:cookie_header, ["langc=en; session=fake; login_md5=fake"]}
  end

  test "spot_config/1 sends no cookie header when WG_COOKIE is unset" do
    System.delete_env("WG_COOKIE")
    test_pid = self()

    Req.Test.stub(HTTPAdapter, fn conn ->
      cookie = Plug.Conn.get_req_header(conn, "cookie")
      send(test_pid, {:cookie_header, cookie})
      Req.Test.json(conn, @spot_config)
    end)

    assert {:ok, _} = HTTPAdapter.spot_config(1_189_718)
    assert_received {:cookie_header, []}
  end

  test "spot_config/1 maps a 500 to an error tuple" do
    Req.Test.stub(HTTPAdapter, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    assert {:error, {:http_status, 500}} = HTTPAdapter.spot_config(1_189_718)
  end

  test "nearest_station/2 resolves nearest from the list endpoint" do
    stub_station_list_fixture()
    assert {:ok, result} = HTTPAdapter.nearest_station(52.36, 5.04)

    case result do
      nil ->
        :ok

      %{id: id, name: name, distance_km: d} ->
        assert is_integer(id) and is_binary(name) and is_number(d)
    end
  end

  test "nearest_station/2 caches the station list for the TTL window (no second HTTP hit)" do
    test_pid = self()

    Req.Test.stub(HTTPAdapter, fn conn ->
      send(test_pid, :station_list_hit)
      Req.Test.json(conn, @stations)
    end)

    assert {:ok, _} = HTTPAdapter.nearest_station(41.26, 1.98)
    assert {:ok, _} = HTTPAdapter.nearest_station(41.26, 1.98)

    assert_received :station_list_hit
    refute_received :station_list_hit
  end

  test "nearest_station/2 sends user-agent and referer headers on station_list request" do
    test_pid = self()

    Req.Test.stub(HTTPAdapter, fn conn ->
      ua = Plug.Conn.get_req_header(conn, "user-agent")
      referer = Plug.Conn.get_req_header(conn, "referer")
      send(test_pid, {:headers, ua, referer})
      Req.Test.json(conn, @stations)
    end)

    assert {:ok, _} = HTTPAdapter.nearest_station(52.36, 5.04)
    assert_received {:headers, [_ua], [_referer]}
  end

  test "windguru 500 falls back to micro, which errors cleanly (not a crash) when unconfigured" do
    # forecast/2 falls back to micro on any iapi error (see moduledoc); with
    # WG_USERNAME/WG_MICRO_PASSWORD unset (this file's setup deletes both),
    # the fallback short-circuits instead of crashing or hitting the network.
    Req.Test.stub(HTTPAdapter, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    assert {:error, :micro_not_configured} = HTTPAdapter.forecast(52.36, 5.04, 3)
  end

  test "non-JSON garbage falls back to micro, which errors cleanly (not a crash) when unconfigured" do
    Req.Test.stub(HTTPAdapter, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>") end)
    assert {:error, :micro_not_configured} = HTTPAdapter.forecast(52.36, 5.04, 3)
  end

  test "iapi 500 falls back to micro and succeeds when micro is reachable and configured" do
    System.put_env("WG_USERNAME", "test-user")
    System.put_env("WG_MICRO_PASSWORD", "test-pass")

    Req.Test.stub(HTTPAdapter, fn conn ->
      case conn.host do
        "micro.windguru.cz" -> Plug.Conn.send_resp(conn, 200, @micro_forecast)
        _ -> Plug.Conn.send_resp(conn, 500, "boom")
      end
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{model: "gfs-micro"}} = HTTPAdapter.forecast(39.92, 3.09, 3)
      end)

    assert log =~ "micro fallback"
  end

  test "401 without WG_COOKIE set falls back to micro, which is unconfigured by default" do
    # The iapi leg still hits :auth_required internally (see translate_auth_error),
    # but forecast/2 now falls back to micro on *any* iapi error, so the final
    # result here reflects the (unconfigured) micro fallback, not the iapi
    # auth signal directly. See the moduledoc note on this tradeoff.
    System.delete_env("WG_COOKIE")

    Req.Test.stub(HTTPAdapter, fn conn ->
      Plug.Conn.send_resp(conn, 401, Jason.encode!(%{"return" => "error"}))
    end)

    assert {:error, :micro_not_configured} = HTTPAdapter.forecast(52.36, 5.04, 3)
  end

  test "403 without WG_COOKIE set falls back to micro, which is unconfigured by default" do
    System.delete_env("WG_COOKIE")

    Req.Test.stub(HTTPAdapter, fn conn ->
      Plug.Conn.send_resp(conn, 403, Jason.encode!(%{"return" => "error"}))
    end)

    assert {:error, :micro_not_configured} = HTTPAdapter.forecast(52.36, 5.04, 3)
  end

  test "401 with WG_COOKIE set falls back to micro, which is unconfigured by default" do
    System.put_env("WG_COOKIE", "langc=en; session=fake; login_md5=fake")

    Req.Test.stub(HTTPAdapter, fn conn ->
      Plug.Conn.send_resp(conn, 401, Jason.encode!(%{"return" => "error"}))
    end)

    assert {:error, :micro_not_configured} = HTTPAdapter.forecast(52.36, 5.04, 3)
  end

  test "forecast/3 with an explicit model sends the cookie header when WG_COOKIE is set" do
    System.put_env("WG_COOKIE", "langc=en; session=fake; login_md5=fake")
    test_pid = self()

    Req.Test.stub(HTTPAdapter, fn conn ->
      cookie = Plug.Conn.get_req_header(conn, "cookie")
      send(test_pid, {:cookie_header, cookie})
      Req.Test.json(conn, @forecast_custom)
    end)

    assert {:ok, _} = HTTPAdapter.forecast(52.36, 5.04, 3)
    assert_received {:cookie_header, ["langc=en; session=fake; login_md5=fake"]}
  end

  test "forecast/3 with an explicit model sends no cookie header when WG_COOKIE is unset" do
    System.delete_env("WG_COOKIE")
    test_pid = self()

    Req.Test.stub(HTTPAdapter, fn conn ->
      cookie = Plug.Conn.get_req_header(conn, "cookie")
      send(test_pid, {:cookie_header, cookie})
      Req.Test.json(conn, @forecast_custom)
    end)

    assert {:ok, _} = HTTPAdapter.forecast(52.36, 5.04, 3)
    assert_received {:cookie_header, []}
  end

  test "forecast/3 with an explicit model sends user-agent and referer headers" do
    test_pid = self()

    Req.Test.stub(HTTPAdapter, fn conn ->
      ua = Plug.Conn.get_req_header(conn, "user-agent")
      referer = Plug.Conn.get_req_header(conn, "referer")
      send(test_pid, {:headers, ua, referer})
      Req.Test.json(conn, @forecast_custom)
    end)

    assert {:ok, _} = HTTPAdapter.forecast(52.36, 5.04, 3)
    assert_received {:headers, [_ua], [_referer]}
  end

  test "station_reading/1 does not send a cookie header even when WG_COOKIE is set" do
    System.put_env("WG_COOKIE", "langc=en; session=fake; login_md5=fake")
    test_pid = self()

    Req.Test.stub(HTTPAdapter, fn conn ->
      cookie = Plug.Conn.get_req_header(conn, "cookie")
      send(test_pid, {:cookie_header, cookie})
      Req.Test.json(conn, @reading)
    end)

    assert {:ok, _} = HTTPAdapter.station_reading(1234)
    assert_received {:cookie_header, []}
  end

  test "station_reading/1 sends user-agent and referer headers" do
    test_pid = self()

    Req.Test.stub(HTTPAdapter, fn conn ->
      ua = Plug.Conn.get_req_header(conn, "user-agent")
      referer = Plug.Conn.get_req_header(conn, "referer")
      send(test_pid, {:headers, ua, referer})
      Req.Test.json(conn, @reading)
    end)

    assert {:ok, _} = HTTPAdapter.station_reading(1234)
    assert_received {:headers, [_ua], [_referer]}
  end

  test "station 500 becomes an error tuple" do
    Req.Test.stub(HTTPAdapter, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    assert {:error, {:http_status, 500}} = HTTPAdapter.station_reading(1234)
  end

  test "station_reading maps 401 without cookie to auth_required" do
    System.delete_env("WG_COOKIE")

    Req.Test.stub(HTTPAdapter, fn conn ->
      Plug.Conn.send_resp(conn, 401, Jason.encode!(%{"return" => "error"}))
    end)

    assert {:error, :auth_required} = HTTPAdapter.station_reading(1234)
  end

  test "station_reading maps 401 with cookie to cookie_expired" do
    System.put_env("WG_COOKIE", "langc=en; session=fake; login_md5=fake")

    Req.Test.stub(HTTPAdapter, fn conn ->
      Plug.Conn.send_resp(conn, 401, Jason.encode!(%{"return" => "error"}))
    end)

    assert {:error, :cookie_expired} = HTTPAdapter.station_reading(1234)
  end

  test "station_reading maps 403 without cookie to auth_required" do
    System.delete_env("WG_COOKIE")

    Req.Test.stub(HTTPAdapter, fn conn ->
      Plug.Conn.send_resp(conn, 403, Jason.encode!(%{"return" => "error"}))
    end)

    assert {:error, :auth_required} = HTTPAdapter.station_reading(1234)
  end

  test "station_list garbage becomes an error tuple, not a crash" do
    Req.Test.stub(HTTPAdapter, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>") end)
    assert {:error, :unexpected_format} = HTTPAdapter.nearest_station(52.36, 5.04)
  end

  describe "stations_near/3" do
    test "returns nearest-first candidates within 30 km, capped at limit" do
      stub_station_list_fixture()
      assert {:ok, stations} = HTTPAdapter.stations_near(39.92, 3.09, 6)
      assert length(stations) >= 1 and length(stations) <= 6
      assert [%{id: _, name: _, distance_km: _} | _] = stations
      distances = Enum.map(stations, & &1.distance_km)
      assert distances == Enum.sort(distances)
      assert Enum.all?(distances, &(&1 <= 30.0))
      # Station 4048 "KiteandYoga Mallorca" (lat 39.858276, lon 3.101116) is
      # the only fixture entry within 30 km of 39.92/3.09 (~6.9 km away); all
      # other Balearic entries are Menorca (~80 km+) or >30 km on Mallorca.
      assert hd(stations).id == 4048
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
      # Station 2367 "Lomas del Cauquen" (lat -41.169515, lon -71.370423,
      # Argentina) is thousands of km from Mallorca — well past the 50 km
      # override bound.
      assert {:ok, nil} = HTTPAdapter.station_by_id(2367, 39.92, 3.09)
    end
  end

  describe "sort/cap/boundary behavior with synthetic station list" do
    # Use ~0.01° lat ≈ 1.112 km to create synthetic stations at known distances
    # Entry helper: creates a station map at a given lat offset from (0.0, 0.0)
    defp entry(id, name, lat) do
      %{
        "id_station" => id,
        "name" => name,
        "lat" => lat,
        "lon" => 0.0,
        "spotname" => name,
        "uid" => "test_#{id}",
        "id_type" => 0,
        "id_spot" => id,
        "wg" => 1,
        "alt" => 0,
        "timezone" => "UTC",
        "seconds_alive" => 100,
        "weather" => %{}
      }
    end

    test "Geo.distance_km validates ~30.03 km entry is actually > 30.0 unrounded" do
      # Verify the test's distance assumption: lat 0.2701 ≈ ~30.03 km
      query_point = {0.0, 0.0}
      station_point = {0.2701, 0.0}
      actual_distance = Stallalert.Geo.distance_km(station_point, query_point)
      assert actual_distance > 30.0
    end

    test "stations_near(0.0, 0.0, 6) returns exactly [12, 11, 13] in distance order (pins sort and round-after-compare)" do
      HTTPAdapter.clear_station_cache()

      synthetic_list = [
        # ~5.6 km
        entry(11, "Station A", 0.05),
        # ~2.2 km
        entry(12, "Station B", 0.02),
        # ~16.7 km
        entry(13, "Station C", 0.15),
        # ~30.03 km (must be EXCLUDED)
        entry(14, "Station D", 0.2701),
        # ~100 km (excluded)
        entry(15, "Station E", 0.9)
      ]

      Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, synthetic_list) end)

      assert {:ok, stations} = HTTPAdapter.stations_near(0.0, 0.0, 6)
      ids = Enum.map(stations, & &1.id)
      assert ids == [12, 11, 13], "Expected [12, 11, 13] but got #{inspect(ids)}"
      # Verify distances are sorted ascending
      distances = Enum.map(stations, & &1.distance_km)
      assert distances == Enum.sort(distances)
      # Verify all are within 30 km
      assert Enum.all?(distances, &(&1 <= 30.0))
    end

    test "stations_near(0.0, 0.0, 2) caps at limit (kills take-off-by-one mutant)" do
      HTTPAdapter.clear_station_cache()

      synthetic_list = [
        entry(11, "Station A", 0.05),
        entry(12, "Station B", 0.02),
        entry(13, "Station C", 0.15)
      ]

      Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, synthetic_list) end)

      assert {:ok, stations} = HTTPAdapter.stations_near(0.0, 0.0, 2)
      ids = Enum.map(stations, & &1.id)
      assert ids == [12, 11], "Expected exactly 2 stations but got #{inspect(ids)}"
    end

    test "station_by_id(14, 0.0, 0.0) returns station at ~30.03 km (within 50 km bound)" do
      HTTPAdapter.clear_station_cache()

      # ~30.03 km (within 50 km)
      synthetic_list = [
        entry(14, "Station D", 0.2701)
      ]

      Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, synthetic_list) end)

      assert {:ok, %{id: 14, name: name, distance_km: d}} =
               HTTPAdapter.station_by_id(14, 0.0, 0.0)

      assert is_binary(name)
      # Rounded to 1 decimal place
      assert d == 30.0
    end

    test "station_by_id(16, 0.0, 0.0) returns nil for station at ~50.03 km (beyond 50 km bound)" do
      HTTPAdapter.clear_station_cache()

      # ~50.03 km (beyond 50 km override limit)
      synthetic_list = [
        entry(16, "Station F", 0.4501)
      ]

      Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, synthetic_list) end)

      assert {:ok, nil} = HTTPAdapter.station_by_id(16, 0.0, 0.0)
    end
  end

  describe "forecast/3 :wg (constituent blend + degradation ladder)" do
    defp stub_by_id_model(handlers) do
      Req.Test.stub(HTTPAdapter, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        handlers.(conn, conn.query_params["id_model"])
      end)
    end

    test "blends every stubbed constituent into a single WG-blend forecast" do
      seed_constituents([3, 52, 104])

      stub_by_id_model(fn conn, id_model ->
        case id_model do
          "3" -> Req.Test.json(conn, @forecast_custom)
          "52" -> Req.Test.json(conn, @forecast_m52)
          "104" -> Req.Test.json(conn, @forecast_m104)
        end
      end)

      assert {:ok, %{model: "WG blend (3 models)", hours: [_ | _]}} =
               HTTPAdapter.forecast(39.92, 3.09, :wg)
    end

    test "one constituent 500ing still blends the remainder" do
      seed_constituents([3, 52, 104])

      stub_by_id_model(fn conn, id_model ->
        case id_model do
          "3" -> Req.Test.json(conn, @forecast_custom)
          "52" -> Plug.Conn.send_resp(conn, 500, "boom")
          "104" -> Req.Test.json(conn, @forecast_m104)
        end
      end)

      assert {:ok, %{model: "WG blend (2 models)"}} = HTTPAdapter.forecast(39.92, 3.09, :wg)
    end

    test "all but one constituent failing ladders down to model 52 (AROME)" do
      seed_constituents([3, 52, 104])

      stub_by_id_model(fn conn, id_model ->
        case id_model do
          "3" -> Plug.Conn.send_resp(conn, 500, "boom")
          "104" -> Plug.Conn.send_resp(conn, 500, "boom")
          "52" -> Req.Test.json(conn, @forecast_m52)
        end
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{model: "AROME-FR 1.3 km"}} = HTTPAdapter.forecast(39.92, 3.09, :wg)
        end)

      assert log =~ "degrading to model 52"
    end

    test "52 also outside-grid ladders all the way down to model 3 (GFS)" do
      seed_constituents([3, 52, 104])

      stub_by_id_model(fn conn, id_model ->
        case id_model do
          "3" -> Req.Test.json(conn, @forecast_custom)
          "104" -> Plug.Conn.send_resp(conn, 500, "boom")
          "52" -> Plug.Conn.send_resp(conn, 404, @outside_grid_body)
        end
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{model: "GFS 13 km"}} = HTTPAdapter.forecast(39.92, 3.09, :wg)
        end)

      assert log =~ "degrading to model 52"
      assert log =~ "degrading to model 3"
    end

    test "an outside-grid constituent is marked unavailable and not re-requested on a later wg call" do
      seed_constituents([3, 52])
      test_pid = self()

      stub_by_id_model(fn conn, id_model ->
        case id_model do
          "3" ->
            Req.Test.json(conn, @forecast_custom)

          "52" ->
            send(test_pid, :model_52_hit)
            Plug.Conn.send_resp(conn, 404, @outside_grid_body)
        end
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{model: "GFS 13 km"}} = HTTPAdapter.forecast(39.92, 3.09, :wg)
        assert {:ok, %{model: "GFS 13 km"}} = HTTPAdapter.forecast(39.92, 3.09, :wg)
      end)

      assert_received :model_52_hit
      refute_received :model_52_hit
    end

    test "fetch spacing threads across the wg_blend -> rung-52 boundary (52 not a constituent)" do
      # 52 is deliberately NOT a constituent here, so the rung-52 live fetch
      # below is a genuinely new dispatch, not a cache hit from the
      # constituent pass -- it's exactly the boundary the spacing discipline
      # must still cover.
      seed_constituents([3, 104])
      Application.put_env(:stallalert, :windguru_spacing_test_hook, self())

      stub_by_id_model(fn conn, id_model ->
        case id_model do
          "3" -> Plug.Conn.send_resp(conn, 500, "boom")
          "104" -> Plug.Conn.send_resp(conn, 500, "boom")
          "52" -> Req.Test.json(conn, @forecast_m52)
        end
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{model: "AROME-FR 1.3 km"}} = HTTPAdapter.forecast(39.92, 3.09, :wg)
        end)

      assert log =~ "degrading to model 52"

      # Three LIVE fetches happen total across the whole call chain
      # (constituents 3, 104, then rung 52) -- two "gaps" between them, so
      # two spacing events fire if and only if the accumulated spacing
      # state threads across the wg_blend -> rung-52 boundary instead of
      # resetting there.
      assert length(collect_spacing_messages()) == 2
    end
  end

  describe "forecast/3 with an explicit integer model" do
    test "forecast(lat, lon, 104) fetches only model 104" do
      test_pid = self()

      stub_by_id_model(fn conn, id_model ->
        send(test_pid, {:hit, id_model})
        Req.Test.json(conn, @forecast_m104)
      end)

      assert {:ok, %{model: "ICON-2I 2.2 km"}} = HTTPAdapter.forecast(39.92, 3.09, 104)
      assert_received {:hit, "104"}
      refute_received {:hit, _}
    end

    test "clear_availability_cache/0 resets a marked-unavailable cell so it is re-requested" do
      stub_by_id_model(fn conn, _id_model ->
        Plug.Conn.send_resp(conn, 404, @outside_grid_body)
      end)

      assert {:error, _} = HTTPAdapter.forecast(39.92, 3.09, 104)

      HTTPAdapter.clear_availability_cache()

      test_pid = self()

      stub_by_id_model(fn conn, id_model ->
        send(test_pid, {:hit, id_model})
        Req.Test.json(conn, @forecast_m104)
      end)

      assert {:ok, %{model: "ICON-2I 2.2 km"}} = HTTPAdapter.forecast(39.92, 3.09, 104)
      assert_received {:hit, "104"}
    end
  end

  describe "available_models/2" do
    test "lists wg first, then named constituents, excluding cell-unavailable models" do
      seed_constituents([3, 52, 104, 999])

      stub_by_id_model(fn conn, id_model ->
        case id_model do
          "52" -> Plug.Conn.send_resp(conn, 404, @outside_grid_body)
          _ -> Plug.Conn.send_resp(conn, 500, "boom")
        end
      end)

      # Mark 52 unavailable for this cell via a real (stubbed) outside-grid
      # fetch, exactly as it would happen in production.
      ExUnit.CaptureLog.capture_log(fn ->
        HTTPAdapter.forecast(39.92, 3.09, 52)
      end)

      assert {:ok, models} = HTTPAdapter.available_models(39.92, 3.09)

      assert models == [
               %{id: "wg", name: "WG blend"},
               %{id: "3", name: "GFS 13 km"},
               %{id: "104", name: "ICON-2I 2.2 km"},
               %{id: "999", name: "Model 999"}
             ]
    end
  end

  describe "FakeAdapter.available_models/2" do
    test "defaults to a healthy wg + AROME + GFS list, and is settable like the other callbacks" do
      assert {:ok,
              [
                %{id: "wg", name: "WG blend"},
                %{id: "52", name: "AROME-FR 1.3 km"},
                %{id: "3", name: "GFS 13 km"}
              ]} = FakeAdapter.available_models(39.92, 3.09)

      FakeAdapter.set(:available_models, {:error, :boom})
      assert {:error, :boom} = FakeAdapter.available_models(39.92, 3.09)
    end
  end
end
