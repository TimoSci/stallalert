defmodule Stallalert.Windguru.HTTPAdapterTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Stallalert.Windguru.HTTPAdapter

  @forecast_custom "test/fixtures/windguru/forecast_custom.json"
                   |> File.read!()
                   |> Jason.decode!()
  @reading "test/fixtures/windguru/station_current.json" |> File.read!() |> Jason.decode!()
  @stations "test/fixtures/windguru/stations_list.json" |> File.read!() |> Jason.decode!()
  @micro_forecast "test/fixtures/windguru/micro_forecast.txt" |> File.read!()

  setup do
    HTTPAdapter.clear_station_cache()

    env_vars = ["WG_COOKIE", "WG_USERNAME", "WG_MICRO_PASSWORD"]
    originals = Map.new(env_vars, &{&1, System.get_env(&1)})
    Enum.each(env_vars, &System.delete_env/1)

    on_exit(fn ->
      HTTPAdapter.clear_station_cache()

      Enum.each(originals, fn
        {var, nil} -> System.delete_env(var)
        {var, val} -> System.put_env(var, val)
      end)
    end)

    :ok
  end

  defp stub_station_list_fixture do
    Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, @stations) end)
  end

  test "forecast/2 fetches and normalizes the custom lat/lon payload" do
    Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, @forecast_custom) end)
    assert {:ok, %{model: "GFS 13 km", hours: [_ | _]}} = HTTPAdapter.forecast(52.36, 5.04)
  end

  test "forecast/2 decodes a JSON body even when the response has a non-JSON content-type" do
    System.put_env("WG_COOKIE", "langc=en; session=fake; login_md5=fake")

    Req.Test.stub(HTTPAdapter, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, File.read!("test/fixtures/windguru/forecast_custom.json"))
    end)

    assert {:ok, %{model: _, hours: [_ | _]}} = HTTPAdapter.forecast(52.36, 5.04)
  end

  test "station_reading/1 fetches and normalizes" do
    Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, @reading) end)
    assert {:ok, %{wind_kn: _}} = HTTPAdapter.station_reading(1234)
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
    assert {:error, :micro_not_configured} = HTTPAdapter.forecast(52.36, 5.04)
  end

  test "non-JSON garbage falls back to micro, which errors cleanly (not a crash) when unconfigured" do
    Req.Test.stub(HTTPAdapter, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>") end)
    assert {:error, :micro_not_configured} = HTTPAdapter.forecast(52.36, 5.04)
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
        assert {:ok, %{model: "gfs-micro"}} = HTTPAdapter.forecast(39.92, 3.09)
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

    assert {:error, :micro_not_configured} = HTTPAdapter.forecast(52.36, 5.04)
  end

  test "403 without WG_COOKIE set falls back to micro, which is unconfigured by default" do
    System.delete_env("WG_COOKIE")

    Req.Test.stub(HTTPAdapter, fn conn ->
      Plug.Conn.send_resp(conn, 403, Jason.encode!(%{"return" => "error"}))
    end)

    assert {:error, :micro_not_configured} = HTTPAdapter.forecast(52.36, 5.04)
  end

  test "401 with WG_COOKIE set falls back to micro, which is unconfigured by default" do
    System.put_env("WG_COOKIE", "langc=en; session=fake; login_md5=fake")

    Req.Test.stub(HTTPAdapter, fn conn ->
      Plug.Conn.send_resp(conn, 401, Jason.encode!(%{"return" => "error"}))
    end)

    assert {:error, :micro_not_configured} = HTTPAdapter.forecast(52.36, 5.04)
  end

  test "forecast/2 sends the cookie header when WG_COOKIE is set" do
    System.put_env("WG_COOKIE", "langc=en; session=fake; login_md5=fake")
    test_pid = self()

    Req.Test.stub(HTTPAdapter, fn conn ->
      cookie = Plug.Conn.get_req_header(conn, "cookie")
      send(test_pid, {:cookie_header, cookie})
      Req.Test.json(conn, @forecast_custom)
    end)

    assert {:ok, _} = HTTPAdapter.forecast(52.36, 5.04)
    assert_received {:cookie_header, ["langc=en; session=fake; login_md5=fake"]}
  end

  test "forecast/2 sends no cookie header when WG_COOKIE is unset" do
    System.delete_env("WG_COOKIE")
    test_pid = self()

    Req.Test.stub(HTTPAdapter, fn conn ->
      cookie = Plug.Conn.get_req_header(conn, "cookie")
      send(test_pid, {:cookie_header, cookie})
      Req.Test.json(conn, @forecast_custom)
    end)

    assert {:ok, _} = HTTPAdapter.forecast(52.36, 5.04)
    assert_received {:cookie_header, []}
  end

  test "forecast/2 sends user-agent and referer headers" do
    test_pid = self()

    Req.Test.stub(HTTPAdapter, fn conn ->
      ua = Plug.Conn.get_req_header(conn, "user-agent")
      referer = Plug.Conn.get_req_header(conn, "referer")
      send(test_pid, {:headers, ua, referer})
      Req.Test.json(conn, @forecast_custom)
    end)

    assert {:ok, _} = HTTPAdapter.forecast(52.36, 5.04)
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
end
