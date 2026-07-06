defmodule Stallalert.Router do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/v1/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok"}))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
