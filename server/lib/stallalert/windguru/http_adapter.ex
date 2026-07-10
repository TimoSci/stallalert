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
    * `forecast/2` falls back to the `micro.windguru.cz` plain-text API (see
      `Stallalert.Windguru.MicroParser`) whenever the `iapi.php` request
      errors (network failure, non-200, undecodable body, auth wall, ...) or
      its body fails to parse into a forecast. The micro fallback requires
      `WG_USERNAME`/`WG_MICRO_PASSWORD`; if either is unset/empty, the
      fallback short-circuits to `{:error, :micro_not_configured}` instead of
      attempting a request.

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

  Note: because `forecast/2` now falls back to the micro API on *any* iapi
  error (see moduledoc above), `:auth_required`/`:cookie_expired` are only
  the final return value of `forecast/2` when the micro fallback is also
  unavailable or unconfigured — they remain accurate as "the iapi leg hit an
  auth wall" signals in logs/traces even when the overall call still
  succeeds via micro.

  ## `forecast/3` and the WG-blend degradation ladder

  `forecast/2` is actually `forecast/3` with `model \\\\ :wg`. `model` is one
  of `:wg | 3 | 52 | 104 | 117 | 64`:

    * `:wg` fetches every `Stallalert.Windguru.BlendConfig.weights/0`
      constituent for this location (each through the per-(0.1° cell,
      model) 15-minute cache below, LIVE fetches spaced `@default_fetch_spacing_ms`
      apart) and blends them with `Stallalert.Windguru.Blend.blend/3`. If
      that yields `{:error, :insufficient_models}` (fewer than 2
      constituents fetched successfully), the ladder degrades to model `52`
      (AROME-FR); if that also fails, to model `3` (GFS, servable for any
      custom lat/lon — see docs/windguru-api-notes.md). Each ladder
      transition logs exactly one `Logger.warning`.
    * An explicit integer `model` fetches only that model. `52` failing
      (including outside-grid) also degrades to `3`, logged the same way;
      the other integers have no further rung (there's nothing more
      universal to fall back to) and just propagate their error.
    * If the whole ladder is exhausted, `forecast/3` falls back to the
      micro API exactly as `forecast/2` always has (see above) — the
      ladder slots in *before* that fallback, not instead of it.

  A "outside grid" 404 (see docs/windguru-api-notes.md) marks that
  (0.1° cell, model) pair unavailable in `:persistent_term` for 6 hours:
  subsequent attempts (whether via `:wg` constituent selection, the ladder,
  or a direct explicit-model request) short-circuit to
  `{:error, :outside_grid}` without dispatching another HTTP request.
  `clear_availability_cache/0` and `clear_forecast_cache/0` are test-only
  escape hatches for both caches, mirroring `clear_station_cache/0`.
  """

  @behaviour Stallalert.Windguru.Adapter

  require Logger

  alias Stallalert.Windguru.{Blend, BlendConfig, ForecastParser, MicroParser, StationParser}
  alias Stallalert.Geo

  @cz_base "https://www.windguru.cz/int/iapi.php"
  @net_base "https://www.windguru.net/int/iapi.php"
  @micro_base "https://micro.windguru.cz/"

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
                "(KHTML, like Gecko) Chrome/124.0 Safari/537.36 StallAlert/1.0"

  @station_cache_key {__MODULE__, :station_list_cache}
  @station_cache_ttl_seconds 6 * 60 * 60

  # Per-(0.1° cell, id_model) forecast cache: avoids re-fetching the same
  # constituent within its 15-minute freshness window, whether it's being
  # requested directly (an explicit integer model) or as part of a `:wg`
  # blend/ladder attempt -- both paths share this cache.
  @forecast_cache_key {__MODULE__, :model_forecast_cache}
  @forecast_cache_ttl_seconds 15 * 60

  # Per-(0.1° cell, id_model) "outside grid" cache: Windguru's custom
  # lat/lon forecast 404s with a documented "outside grid" body (see
  # docs/windguru-api-notes.md) when a regional model's grid doesn't cover
  # the requested coordinates. That's a property of the (cell, model) pair,
  # not a transient failure, so it's remembered for 6h to avoid hammering a
  # model that can never succeed for this location -- both for `:wg`
  # constituent selection and for the ladder/explicit-model paths.
  @unavailable_cache_key {__MODULE__, :model_unavailable_cache}
  @unavailable_ttl_seconds 6 * 60 * 60

  # Minimum spacing enforced between consecutive LIVE (non-cached) forecast
  # fetches, so a `:wg` blend attempt (which may dispatch up to ~10
  # constituent requests) doesn't hammer Windguru back-to-back. Cached hits
  # never sleep. Configurable via app env so tests can zero it out instead
  # of taking minutes; defaults to 0 in `config/test.exs`.
  @default_fetch_spacing_ms 2_500

  @model_names %{
    3 => "GFS 13 km",
    52 => "AROME-FR 1.3 km",
    104 => "ICON-2I 2.2 km",
    117 => "IFS-HRES 9 km",
    64 => "Zephr-HD 2.6 km"
  }

  # `stations_near/3` candidate radius: mirrors `Geo`'s own 30 km
  # "representative" bound, offering a few nearby override choices.
  # `station_by_id/3` allows a wider 50 km leash for an explicit user
  # override — a user may reasonably know a station a bit farther out is
  # still representative, even if it wouldn't be auto-selected as "nearest".
  @candidate_radius_km 30.0
  @override_max_km 50.0

  @impl true
  def forecast(lat, lon, model \\ :wg) do
    case forecast_ladder(lat, lon, model) do
      {:ok, forecast} ->
        {:ok, forecast}

      {:error, reason} ->
        Logger.warning(
          "windguru forecast failed (model=#{inspect(model)}, reason=#{inspect(reason)}); " <>
            "attempting micro fallback"
        )

        micro_forecast(lat, lon)
    end
  end

  @doc """
  Models servable for `lat`/`lon`: the synthetic `"wg"` blend followed by
  whichever WG-blend constituents (per `BlendConfig.weights/0`) aren't
  currently marked unavailable (outside-grid) for this location's 0.1°
  cell. Names come from `@model_names`; an unmapped constituent id falls
  back to `"Model <id>"`.
  """
  @impl true
  def available_models(lat, lon) do
    cell = cell(lat, lon)
    %{constituents: constituents} = BlendConfig.weights()

    models =
      constituents
      |> Enum.reject(&unavailable?(cell, &1))
      |> Enum.map(fn id -> %{id: Integer.to_string(id), name: model_name(id)} end)

    {:ok, [%{id: "wg", name: "WG blend"} | models]}
  end

  # The degradation ladder: `:wg` (blend of all fetchable constituents) ->
  # `52` (AROME-FR) -> `3` (GFS, the universal fallback -- servable for any
  # custom lat/lon, see docs/windguru-api-notes.md). Any other explicitly
  # requested integer model is a single-shot fetch with no further ladder
  # step (nothing more specific to fall back to). Each transition logs
  # exactly one warning before trying the next rung.
  #
  # The fetch-spacing accumulator (`spacing_state`) is threaded through the
  # whole recursion -- every rung both accepts and returns it -- so a live
  # dispatch at a rung boundary (e.g. a fresh `52` fetch right after the
  # `:wg` constituent pass) is still spaced from whatever LIVE fetch came
  # immediately before it, instead of starting each rung as if it were the
  # first fetch of the call.
  defp forecast_ladder(lat, lon, model) do
    {result, _spacing_state} = forecast_ladder(lat, lon, model, initial_spacing_state())
    result
  end

  defp forecast_ladder(lat, lon, :wg, spacing_state) do
    {blend_result, spacing_state} = wg_blend(lat, lon, spacing_state)

    case blend_result do
      {:ok, _forecast} = ok ->
        {ok, spacing_state}

      {:error, reason} ->
        Logger.warning(
          "windguru WG blend for #{lat},#{lon} failed (#{inspect(reason)}); " <>
            "degrading to model 52 (AROME-FR 1.3 km)"
        )

        forecast_ladder(lat, lon, 52, spacing_state)
    end
  end

  defp forecast_ladder(lat, lon, 52, spacing_state) do
    {result, spacing_state} = fetch_cached(lat, lon, 52, spacing_state)

    case result do
      {:ok, _forecast} = ok ->
        {ok, spacing_state}

      {:error, reason} ->
        Logger.warning(
          "windguru model 52 (AROME-FR 1.3 km) unavailable for #{lat},#{lon} " <>
            "(#{inspect(reason)}); degrading to model 3 (GFS 13 km)"
        )

        forecast_ladder(lat, lon, 3, spacing_state)
    end
  end

  defp forecast_ladder(lat, lon, model, spacing_state) when model in [3, 104, 117, 64] do
    fetch_cached(lat, lon, model, spacing_state)
  end

  # Fetches every currently-fetchable WG-blend constituent (per
  # `BlendConfig.weights/0`, minus this cell's outside-grid-unavailable
  # models -- enforced inside `fetch_cached/4`, which short-circuits
  # without an HTTP call for a model already known unavailable here) and
  # blends whatever succeeds. `Blend.blend/3` itself requires >= 2
  # successful constituents to produce a result. Returns the accumulated
  # `spacing_state` alongside the blend result so a subsequent ladder rung
  # (see `forecast_ladder/4`) can keep spacing its own live fetch from the
  # last one dispatched here.
  defp wg_blend(lat, lon, spacing_state) do
    %{constituents: constituents, koef: koef} = BlendConfig.weights()

    {results, spacing_state} =
      Enum.map_reduce(constituents, spacing_state, fn model, spacing_state ->
        {result, spacing_state} = fetch_cached(lat, lon, model, spacing_state)
        {{model, result}, spacing_state}
      end)

    forecasts =
      results
      |> Enum.filter(fn {_model, result} -> match?({:ok, _}, result) end)
      |> Enum.map(fn {model, {:ok, forecast}} -> {model, forecast} end)

    {Blend.blend(forecasts, koef, DateTime.utc_now()), spacing_state}
  end

  defp initial_spacing_state, do: %{live_fetched?: false}

  # Serves a per-(cell, model) cached forecast when fresh; otherwise, if
  # the (cell, model) pair isn't known outside-grid-unavailable, dispatches
  # a LIVE fetch (spaced from any prior live fetch made earlier in this
  # same call chain) and caches a successful result. A model already known
  # unavailable for this cell short-circuits to `{:error, :outside_grid}`
  # with no HTTP call and no effect on fetch spacing.
  defp fetch_cached(lat, lon, model, spacing_state) do
    cell = cell(lat, lon)

    case cache_get(cell, model) do
      {:ok, forecast} ->
        {{:ok, forecast}, spacing_state}

      :miss ->
        if unavailable?(cell, model) do
          {{:error, :outside_grid}, spacing_state}
        else
          spacing_state = maybe_sleep(spacing_state)
          result = fetch_model_live(lat, lon, model)

          case result do
            {:ok, forecast} -> cache_put(cell, model, forecast)
            _ -> :ok
          end

          {result, %{spacing_state | live_fetched?: true}}
        end
    end
  end

  defp maybe_sleep(%{live_fetched?: true} = spacing_state) do
    ms = fetch_spacing_ms()
    notify_spacing_test_hook(ms)
    Process.sleep(ms)
    spacing_state
  end

  defp maybe_sleep(spacing_state), do: spacing_state

  defp fetch_spacing_ms,
    do: Application.get_env(:stallalert, :windguru_fetch_spacing_ms, @default_fetch_spacing_ms)

  # Test-only hook: when `windguru_spacing_test_hook` is set (to a pid) in
  # app env, every spacing sleep sends `{:spacing_applied, ms}` to it first.
  # Lets tests structurally prove the fetch-spacing accumulator threads
  # across the ladder (see http_adapter_test.exs) without depending on wall-
  # clock timing -- `windguru_fetch_spacing_ms` is 0 in test config, so
  # timing alone can't distinguish "spaced" from "not spaced". Unset in
  # every non-test env; a no-op there.
  defp notify_spacing_test_hook(ms) do
    case Application.get_env(:stallalert, :windguru_spacing_test_hook) do
      nil -> :ok
      pid -> send(pid, {:spacing_applied, ms})
    end
  end

  # A single, uncached live fetch for one model. Marks the (cell, model)
  # pair unavailable when Windguru reports it as outside the model's grid.
  defp fetch_model_live(lat, lon, model_id) do
    headers = base_headers() |> maybe_add_cookie()
    params = %{q: "forecast", id_model: model_id, lat: lat, lon: lon}

    case get(@cz_base, params, headers) do
      {:ok, body} ->
        ForecastParser.parse(body)

      {:error, :outside_grid} = error ->
        mark_unavailable(cell(lat, lon), model_id)
        error

      {:error, _reason} = error ->
        error
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

  @impl true
  def stations_near(lat, lon, limit) do
    with {:ok, stations} <- fetch_station_list() do
      {:ok,
       stations
       |> Enum.map(&compute_distance(&1, lat, lon))
       |> Enum.filter(&(&1.unrounded <= @candidate_radius_km))
       |> Enum.sort_by(& &1.unrounded)
       |> Enum.map(&format_station/1)
       |> Enum.take(limit)}
    end
  end

  @impl true
  def spot_config(id_spot) do
    headers = base_headers() |> maybe_add_cookie()
    params = %{q: "forecast_spot", id_spot: id_spot}
    get(@cz_base, params, headers)
  end

  @impl true
  def station_by_id(id, lat, lon) do
    with {:ok, stations} <- fetch_station_list() do
      case Enum.find(stations, &(&1.id == id)) do
        nil ->
          {:ok, nil}

        s ->
          distance_record = compute_distance(s, lat, lon)

          if distance_record.unrounded <= @override_max_km,
            do: {:ok, format_station(distance_record)},
            else: {:ok, nil}
      end
    end
  end

  # Compute distance without rounding (for filtering/comparison).
  defp compute_distance(%{id: id, name: name, lat: s_lat, lon: s_lon}, lat, lon) do
    unrounded = Geo.distance_km({s_lat, s_lon}, {lat, lon})

    %{
      id: id,
      name: name,
      unrounded: unrounded
    }
  end

  # Format a distance record with rounding applied.
  defp format_station(%{id: id, name: name, unrounded: unrounded}) do
    %{
      id: id,
      name: name,
      distance_km: Float.round(unrounded, 1)
    }
  end

  @doc false
  # Test-only escape hatch so the station-list cache doesn't leak state
  # between tests (or between a stale run and a fresh one).
  def clear_station_cache, do: :persistent_term.erase(@station_cache_key)

  @doc false
  # Test-only escape hatch: forgets every (cell, model) marked
  # outside-grid-unavailable, so a later fetch attempt actually re-dispatches
  # instead of short-circuiting on stale test state.
  def clear_availability_cache, do: :persistent_term.erase(@unavailable_cache_key)

  @doc false
  # Test-only escape hatch: empties the per-(cell, model) 15-minute forecast
  # cache, mirroring `clear_station_cache/0`.
  def clear_forecast_cache, do: :persistent_term.erase(@forecast_cache_key)

  defp cache_get(cell, model) do
    case Map.get(:persistent_term.get(@forecast_cache_key, %{}), {cell, model}) do
      nil ->
        :miss

      {fetched_at, forecast} ->
        if System.system_time(:second) - fetched_at < @forecast_cache_ttl_seconds do
          {:ok, forecast}
        else
          :miss
        end
    end
  end

  defp cache_put(cell, model, forecast) do
    cache = :persistent_term.get(@forecast_cache_key, %{})
    entry = {System.system_time(:second), forecast}
    :persistent_term.put(@forecast_cache_key, Map.put(cache, {cell, model}, entry))
  end

  defp mark_unavailable(cell, model) do
    cache = :persistent_term.get(@unavailable_cache_key, %{})
    :persistent_term.put(@unavailable_cache_key, Map.put(cache, {cell, model}, now_seconds()))
  end

  defp unavailable?(cell, model) do
    case Map.get(:persistent_term.get(@unavailable_cache_key, %{}), {cell, model}) do
      nil -> false
      marked_at -> now_seconds() - marked_at < @unavailable_ttl_seconds
    end
  end

  defp now_seconds, do: System.system_time(:second)

  # Buckets a lat/lon into a 0.1°-resolution cell for the per-location
  # caches above -- coarse enough that nearby requests share cache entries,
  # fine enough to respect a regional model's actual grid boundary.
  defp cell(lat, lon), do: {round1(lat), round1(lon)}
  defp round1(x), do: Float.round(x * 1.0, 1)

  defp model_name(id), do: Map.get(@model_names, id, "Model #{id}")

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

  # `iapi.php` (JSON) failed or its body didn't parse into a forecast — try
  # the plain-text `micro.windguru.cz` fallback before giving up entirely.
  # Only `m=gfs` returns a real forecast table on the micro API (`m=wg`, a
  # guessed WG-blend id, returns an empty table); see
  # `docs/windguru-api-notes.md`.
  defp micro_forecast(lat, lon) do
    with {:ok, username} <- fetch_micro_env("WG_USERNAME"),
         {:ok, password} <- fetch_micro_env("WG_MICRO_PASSWORD"),
         {:ok, body} <- fetch_micro_body(lat, lon, username, password) do
      MicroParser.parse(body)
    end
  end

  defp fetch_micro_env(var) do
    case System.get_env(var) do
      nil -> {:error, :micro_not_configured}
      "" -> {:error, :micro_not_configured}
      value -> {:ok, value}
    end
  end

  # Deliberately not routed through `request/3`: the micro API returns an
  # HTML/text body, not JSON, so `request/3`'s JSON-decode-a-raw-binary path
  # doesn't apply here — a 200 binary body is handed to `MicroParser` as-is.
  defp fetch_micro_body(lat, lon, username, password) do
    opts = Application.get_env(:stallalert, :windguru_req_options, [])
    params = %{lat: lat, lon: lon, m: "gfs", u: username, p: password}

    req =
      Req.new(
        [
          base_url: @micro_base,
          params: params,
          headers: base_headers(),
          retry: false,
          receive_timeout: 3_500,
          connect_options: [timeout: 2_500]
        ] ++ opts
      )

    case Req.get(req) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200}} ->
        {:error, :unexpected_format}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
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
      Req.new(
        [
          base_url: base_url,
          params: params,
          headers: headers,
          retry: false,
          receive_timeout: 3_500,
          connect_options: [timeout: 2_500]
        ] ++ opts
      )

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

      {:ok, %Req.Response{status: 404, body: body}} ->
        translate_404(body)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Windguru's custom lat/lon forecast 404s with a documented body shape
  # when a regional model's grid doesn't cover the requested coordinates
  # (see "outside grid" in docs/windguru-api-notes.md). Distinguish that
  # from a generic 404 so callers can mark the (cell, model) unavailable
  # instead of treating it as a one-off transient error.
  defp translate_404(body) when is_map(body) do
    if outside_grid?(body), do: {:error, :outside_grid}, else: {:error, {:http_status, 404}}
  end

  defp translate_404(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> translate_404(decoded)
      {:error, _reason} -> {:error, {:http_status, 404}}
    end
  end

  defp translate_404(_body), do: {:error, {:http_status, 404}}

  defp outside_grid?(%{"message" => message}) when is_binary(message) do
    String.contains?(String.downcase(message), "outside grid")
  end

  defp outside_grid?(_body), do: false

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
