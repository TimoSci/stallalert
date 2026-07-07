defmodule Stallalert.Windguru.HTTPAdapter do
  @moduledoc """
  Live HTTP adapter for the undocumented Windguru `iapi.php` endpoints.

  See `docs/windguru-api-notes.md` for the empirical basis of every
  URL/header/param choice below. Summary:

    * `forecast/2` hits the custom lat/lon forecast (a PRO-gated feature) on
      `www.windguru.cz`. It requires `User-Agent` + `Referer` + the **full**
      opaque session cookie (read from the `WG_COOKIE` env var at call time —
      see the module doc on cookie strategy below).
    * `station_reading/1` hits the live station endpoint on the same host.
      No cookie is sent — the endpoint was found to work with just
      `User-Agent` + `Referer` for the tested (public) station.
    * `nearest_station/2` hits the global station list on `www.windguru.net`,
      which requires `User-Agent` + `Referer` (as of 2026-07-07; bare requests
      return 401). The raw payload is ~1.16 MB, so the parsed station list is
      cached in `:persistent_term` for 6 hours to avoid hammering Windguru on
      every station refresh.

  Response bodies are decoded content-type-independently: `iapi.php` is a
  legacy, undocumented PHP endpoint, and while probing found it currently
  sends a genuine JSON `Content-Type` (see "Content-Type findings" in
  `docs/windguru-api-notes.md`), that's an observation, not a guarantee.
  Rather than depend on `Req`'s auto-decode (which only triggers for a
  recognized JSON content-type), a 200 response with a raw binary body is
  explicitly run through `Jason.decode/1` here, so a mislabeled or missing
  `Content-Type` header can't turn every success into `:unexpected_format`.

  ## Cookie strategy

  No automated login flow was discovered within this task's probing budget
  (see `docs/windguru-api-notes.md`, "Open risk: session-cookie acquisition"
  for the exact probe log). `WG_COOKIE` is therefore expected to be an
  opaque, manually-refreshed browser session cookie string, read fresh from
  the environment on every call (never cached, never logged):

    * If `WG_COOKIE` is unset/empty and a call comes back 401/403, that call
      returns `{:error, :auth_required}`.
    * If `WG_COOKIE` is set and a call still comes back 401/403 (i.e. the
      cookie has expired), that call returns `{:error, :cookie_expired}`.

  This applies uniformly to all three endpoints for a consistent error
  contract, even though only `forecast/2` is known to actually require the
  cookie today.
  """

  @behaviour Stallalert.Windguru.Adapter

  alias Stallalert.Windguru.{ForecastParser, StationParser}
  alias Stallalert.Geo

  @cz_base "https://www.windguru.cz/int/iapi.php"
  @net_base "https://www.windguru.net/int/iapi.php"

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
                "(KHTML, like Gecko) Chrome/124.0 Safari/537.36 StallAlert/1.0"

  @station_cache_key {__MODULE__, :station_list_cache}
  @station_cache_ttl_seconds 6 * 60 * 60

  @impl true
  def forecast(lat, lon) do
    headers = base_headers() |> maybe_add_cookie()

    params = %{q: "forecast", id_model: 3, lat: lat, lon: lon}

    with {:ok, body} <- get(@cz_base, params, headers) do
      ForecastParser.parse(body)
    end
  end

  @impl true
  def station_reading(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    from = DateTime.add(now, -60 * 60, :second) |> DateTime.to_iso8601()
    to = DateTime.to_iso8601(now)

    params = %{q: "station_data", id_station: id, from: from, to: to, avg_minutes: 5}

    with {:ok, body} <- get(@cz_base, params, base_headers()) do
      StationParser.parse_reading(body)
    end
  end

  @impl true
  def nearest_station(lat, lon) do
    with {:ok, stations} <- fetch_station_list() do
      case Geo.nearest(stations, {lat, lon}) do
        nil -> {:ok, nil}
        {s, d} -> {:ok, %{id: s.id, name: s.name, distance_km: Float.round(d, 1)}}
      end
    end
  end

  @doc false
  # Test-only escape hatch so the station-list cache doesn't leak state
  # between tests (or between a stale run and a fresh one).
  def clear_station_cache, do: :persistent_term.erase(@station_cache_key)

  defp fetch_station_list do
    # Check-then-put race accepted: this is single-node with a 6h TTL, so the
    # worst case of two concurrent callers both missing the cache is a
    # duplicate fetch (both write the same result), not a correctness bug.
    case :persistent_term.get(@station_cache_key, nil) do
      {fetched_at, stations} ->
        if System.system_time(:second) - fetched_at < @station_cache_ttl_seconds do
          {:ok, stations}
        else
          fetch_and_cache_station_list()
        end

      nil ->
        fetch_and_cache_station_list()
    end
  end

  defp fetch_and_cache_station_list do
    params = %{q: "station_list", id_type: 0, seconds: 1800, seconds_alive: 172_800}

    with {:ok, body} <- get(@net_base, params, base_headers()),
         {:ok, stations} <- StationParser.parse_station_list(body) do
      :persistent_term.put(@station_cache_key, {System.system_time(:second), stations})
      {:ok, stations}
    end
  end

  defp base_headers do
    [{"user-agent", @user_agent}, {"referer", "https://www.windguru.cz/"}]
  end

  defp get(base_url, params, headers) do
    base_url
    |> request(params, headers)
    |> translate_auth_error()
  end

  defp request(base_url, params, headers) do
    opts = Application.get_env(:stallalert, :windguru_req_options, [])

    req =
      Req.new([base_url: base_url, params: params, headers: headers, retry: false] ++ opts)

    case Req.get(req) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) or is_list(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        # Req only auto-decodes JSON when it recognizes the response's
        # Content-Type; `iapi.php` is a legacy, undocumented endpoint whose
        # Content-Type behavior isn't guaranteed to stay JSON forever (see
        # "Content-Type findings" in docs/windguru-api-notes.md). Decode
        # explicitly here so a mislabeled/missing Content-Type doesn't turn
        # every success into an error.
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _reason} -> {:error, :unexpected_format}
        end

      {:ok, %Req.Response{status: 200}} ->
        {:error, :unexpected_format}

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:error, {:auth, status}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp translate_auth_error({:error, {:auth, _status}}) do
    case cookie() do
      nil -> {:error, :auth_required}
      _ -> {:error, :cookie_expired}
    end
  end

  defp translate_auth_error(other), do: other

  defp maybe_add_cookie(headers) do
    case cookie() do
      nil -> headers
      value -> headers ++ [{"cookie", value}]
    end
  end

  defp cookie do
    case System.get_env("WG_COOKIE") do
      nil -> nil
      "" -> nil
      value -> value
    end
  end
end
