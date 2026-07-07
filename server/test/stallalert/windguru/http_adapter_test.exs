defmodule Stallalert.Windguru.HTTPAdapterTest do
  use ExUnit.Case, async: false
  alias Stallalert.Windguru.HTTPAdapter

  @forecast_custom "test/fixtures/windguru/forecast_custom.json"
                   |> File.read!()
                   |> Jason.decode!()
  @reading "test/fixtures/windguru/station_current.json" |> File.read!() |> Jason.decode!()
  @stations "test/fixtures/windguru/stations_list.json" |> File.read!() |> Jason.decode!()

  setup do
    HTTPAdapter.clear_station_cache()
    original = System.get_env("WG_COOKIE")
    System.delete_env("WG_COOKIE")

    on_exit(fn ->
      HTTPAdapter.clear_station_cache()

      case original do
        nil -> System.delete_env("WG_COOKIE")
        val -> System.put_env("WG_COOKIE", val)
      end
    end)

    :ok
  end

  test "forecast/2 fetches and normalizes the custom lat/lon payload" do
    Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, @forecast_custom) end)
    assert {:ok, %{model: "GFS 13 km", hours: [_ | _]}} = HTTPAdapter.forecast(52.36, 5.04)
  end

  test "station_reading/1 fetches and normalizes" do
    Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, @reading) end)
    assert {:ok, %{wind_kn: _}} = HTTPAdapter.station_reading(1234)
  end

  test "nearest_station/2 resolves nearest from the list endpoint" do
    Req.Test.stub(HTTPAdapter, fn conn -> Req.Test.json(conn, @stations) end)
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

  test "windguru 500 becomes an error tuple" do
    Req.Test.stub(HTTPAdapter, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    assert {:error, {:http_status, 500}} = HTTPAdapter.forecast(52.36, 5.04)
  end

  test "non-JSON garbage becomes an error tuple, not a crash" do
    Req.Test.stub(HTTPAdapter, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>") end)
    assert {:error, :unexpected_format} = HTTPAdapter.forecast(52.36, 5.04)
  end

  test "401 without WG_COOKIE set returns :auth_required" do
    System.delete_env("WG_COOKIE")

    Req.Test.stub(HTTPAdapter, fn conn ->
      Plug.Conn.send_resp(conn, 401, Jason.encode!(%{"return" => "error"}))
    end)

    assert {:error, :auth_required} = HTTPAdapter.forecast(52.36, 5.04)
  end

  test "403 without WG_COOKIE set returns :auth_required" do
    System.delete_env("WG_COOKIE")

    Req.Test.stub(HTTPAdapter, fn conn ->
      Plug.Conn.send_resp(conn, 403, Jason.encode!(%{"return" => "error"}))
    end)

    assert {:error, :auth_required} = HTTPAdapter.forecast(52.36, 5.04)
  end

  test "401 with WG_COOKIE set returns :cookie_expired" do
    System.put_env("WG_COOKIE", "langc=en; session=fake; login_md5=fake")

    Req.Test.stub(HTTPAdapter, fn conn ->
      Plug.Conn.send_resp(conn, 401, Jason.encode!(%{"return" => "error"}))
    end)

    assert {:error, :cookie_expired} = HTTPAdapter.forecast(52.36, 5.04)
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

  test "station 500 becomes an error tuple" do
    Req.Test.stub(HTTPAdapter, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    assert {:error, {:http_status, 500}} = HTTPAdapter.station_reading(1234)
  end

  test "station_list garbage becomes an error tuple, not a crash" do
    Req.Test.stub(HTTPAdapter, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>") end)
    assert {:error, :unexpected_format} = HTTPAdapter.nearest_station(52.36, 5.04)
  end
end
