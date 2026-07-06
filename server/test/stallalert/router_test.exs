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
