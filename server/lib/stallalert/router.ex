defmodule Stallalert.Router do
  use Plug.Router

  plug(Stallalert.Auth)
  plug(:match)
  plug(:dispatch)

  get "/v1/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok"}))
  end

  get "/v1/conditions" do
    conn = fetch_query_params(conn)

    with {lat, ""} <- Float.parse(conn.query_params["lat"] || ""),
         {lon, ""} <- Float.parse(conn.query_params["lon"] || "") do
      case Stallalert.Conditions.get(lat, lon) do
        {:ok, payload} -> json(conn, 200, serialize(payload))
        {:error, :no_data} -> json(conn, 503, %{error: "no data available yet"})
      end
    else
      _ -> json(conn, 422, %{error: "lat and lon are required floats"})
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp serialize(payload) do
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

    hours =
      payload.forecast.hours
      |> Enum.filter(&(DateTime.compare(&1.time, cutoff) != :lt))
      |> Enum.take(12)

    %{
      generated_at: payload.generated_at,
      stale: payload.stale,
      forecast: %{payload.forecast | hours: hours},
      station: payload.station
    }
  end
end
