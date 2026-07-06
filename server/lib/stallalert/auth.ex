defmodule Stallalert.Auth do
  import Plug.Conn

  def init(opts), do: opts

  # Health stays open; everything else needs the bearer token.
  def call(%Plug.Conn{path_info: ["v1", "health"]} = conn, _opts), do: conn

  def call(conn, _opts) do
    expected = Application.fetch_env!(:stallalert, :api_token)

    case get_req_header(conn, "authorization") do
      ["Bearer " <> ^expected] -> conn
      _ -> conn |> send_resp(401, "unauthorized") |> halt()
    end
  end
end
