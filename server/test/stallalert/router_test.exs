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

  # `Stallalert.Conditions`'s forecast leg is fetched by a background `Task`
  # (see its moduledoc), so a cold slot (no forecast cached yet for this
  # position+model combination) answers 503 on the first hit while it
  # refreshes in the background. These router tests share ONE global
  # `Stallalert.Conditions` singleton (started by the application, not a
  # fresh per-test instance), so warm it up once here before any test
  # depends on a 200 -- everything after that serves from cache within TTL.
  setup_all do
    eventually(fn -> authed_get("/v1/conditions?lat=52.36&lon=5.04").status == 200 end)
    :ok
  end

  defp eventually(pred, tries \\ 200) do
    if pred.() do
      :ok
    else
      if tries > 0 do
        Process.sleep(5)
        eventually(pred, tries - 1)
      else
        flunk("condition never became true")
      end
    end
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
      # This suite shares ONE global `Stallalert.Conditions` singleton
      # across every test (see `setup_all` above), and other tests in this
      # file switch its cached model -- so make sure "wg" is the one
      # actually being served (not merely 200 with stale last-good data
      # for whatever model a sibling test last requested) before asserting
      # on its content.
      eventually(fn ->
        body = Jason.decode!(authed_get("/v1/conditions?lat=52.36&lon=5.04").resp_body)
        body["forecast"]["model"] == "wg"
      end)

      conn = authed_get("/v1/conditions?lat=52.36&lon=5.04")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert %{"generated_at" => _, "stale" => false, "forecast" => f, "station" => s} = body
      assert %{"model" => "wg", "init_time" => _, "hours" => [h | _]} = f
      assert %{"time" => _, "wind_kn" => _, "gust_kn" => _, "dir_deg" => _} = h
      assert %{"id" => _, "name" => _, "distance_km" => _, "reading" => _} = s
      assert [%{"time" => _, "dir_deg" => _} | _] = s["reading"]["direction_history"]
    end

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

    test "payload includes requested_model and available_models on the wire" do
      body = Jason.decode!(authed_get("/v1/conditions?lat=52.36&lon=5.04").resp_body)
      assert body["requested_model"] == "wg"

      assert [%{"id" => _, "name" => _} | _] = body["available_models"]
      assert Enum.any?(body["available_models"], &(&1["id"] == "wg"))
    end

    test "model param is honored and echoed once its background fetch lands" do
      eventually(fn ->
        body = Jason.decode!(authed_get("/v1/conditions?lat=52.36&lon=5.04&model=52").resp_body)
        body["requested_model"] == "52" and body["forecast"]["model"] == "52"
      end)

      body = Jason.decode!(authed_get("/v1/conditions?lat=52.36&lon=5.04&model=52").resp_body)
      assert body["requested_model"] == "52"
      assert body["forecast"]["model"] == "52"
    end

    test "an unrecognized model param defaults to wg" do
      # Not a "wg"/numeric descriptor -> the router normalizes it to "wg"
      # before it ever reaches Conditions. (Not necessarily synchronous: a
      # prior test in this shared-singleton suite may have last switched
      # the cache to a different model, in which case this is itself a
      # switch back to "wg" and needs its own background fetch to land.)
      eventually(fn ->
        body =
          Jason.decode!(authed_get("/v1/conditions?lat=52.36&lon=5.04&model=bogus").resp_body)

        body["requested_model"] == "wg" and body["forecast"]["model"] == "wg"
      end)

      body = Jason.decode!(authed_get("/v1/conditions?lat=52.36&lon=5.04&model=bogus").resp_body)
      assert body["requested_model"] == "wg"
      assert body["forecast"]["model"] == "wg"
    end

    # Regression for the whole-branch review's Critical #1: a digit `model=`
    # outside the ladder's supported domain (`{3, 52, 104, 117, 64}`) must be
    # normalized to "wg" by the router -- same as any other unrecognized
    # descriptor -- per the spec's "Unknown values -> treated as wg" and so
    # this out-of-domain id can never reach `Conditions`/the adapter, no
    # matter what BlendConfig's constituent snapshot advertises.
    test "an out-of-domain numeric model param (not in the ladder's whitelist) defaults to wg" do
      for model <- ["45", "999"] do
        eventually(fn ->
          body =
            Jason.decode!(
              authed_get("/v1/conditions?lat=52.36&lon=5.04&model=#{model}").resp_body
            )

          body["requested_model"] == "wg" and body["forecast"]["model"] == "wg"
        end)

        body =
          Jason.decode!(authed_get("/v1/conditions?lat=52.36&lon=5.04&model=#{model}").resp_body)

        assert body["requested_model"] == "wg"
        assert body["forecast"]["model"] == "wg"
      end
    end
  end

  defp authed_get(path) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{@token}")
    |> Stallalert.Router.call(@opts)
  end
end
