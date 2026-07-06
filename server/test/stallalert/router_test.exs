defmodule Stallalert.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts Stallalert.Router.init([])
  @token "test-token"

  setup do
    Stallalert.FakeAdapter.reset()
    :ok
  end

  test "GET /v1/health returns 200 ok without auth" do
    conn = conn(:get, "/v1/health") |> Stallalert.Router.call(@opts)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
  end

  test "unknown route returns 404" do
    conn =
      conn(:get, "/nope")
      |> put_req_header("authorization", "Bearer #{@token}")
      |> Stallalert.Router.call(@opts)

    assert conn.status == 404
  end

  describe "GET /v1/conditions" do
    test "401 without bearer token" do
      conn = conn(:get, "/v1/conditions?lat=52.36&lon=5.04") |> Stallalert.Router.call(@opts)
      assert conn.status == 401
    end

    test "422 with missing or non-numeric lat/lon" do
      for qs <- ["", "lat=52.36", "lat=abc&lon=5.04"] do
        conn =
          conn(:get, "/v1/conditions?" <> qs)
          |> put_req_header("authorization", "Bearer #{@token}")
          |> Stallalert.Router.call(@opts)

        assert conn.status == 422
      end
    end

    test "200 with normalized payload" do
      conn =
        conn(:get, "/v1/conditions?lat=52.36&lon=5.04")
        |> put_req_header("authorization", "Bearer #{@token}")
        |> Stallalert.Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert %{"generated_at" => _, "stale" => false, "forecast" => f, "station" => s} = body
      assert %{"model" => "wg", "init_time" => _, "hours" => [h | _]} = f
      assert %{"time" => _, "wind_kn" => _, "gust_kn" => _, "dir_deg" => _} = h
      assert %{"id" => _, "name" => _, "distance_km" => _, "reading" => _} = s
    end
  end
end
