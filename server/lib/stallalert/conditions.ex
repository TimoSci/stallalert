defmodule Stallalert.Conditions do
  @moduledoc """
  Caches normalized windguru data for the last requested position and
  refreshes it in the background (forecast 15 min, station 5 min).

  The station leg supports an optional per-request `:station_id` override
  (see `get/4`). When given and the adapter resolves it to a real station,
  that station's reading is served with `source: "manual"`; otherwise (no
  override, or an unknown/out-of-range id) the nearest station is served
  with `source: "auto"`. Switching between overrides (or between an
  override and auto) invalidates the cached station entry immediately,
  even if it is otherwise within its TTL and the rider hasn't moved.

  The forecast leg supports an optional per-request `:model` override (see
  `get/4`): `nil` or `"wg"` requests the WG-blend, and a numeric string
  (e.g. `"52"`) requests that single constituent model directly. Like the
  station override, the verbatim requested-model descriptor is recorded on
  the forecast entry (`requested`) so that switching models invalidates the
  cache immediately while identical repeats (including within the string
  domain the adapter can't fully satisfy) stay cache-stable.

  ## Async forecast refresh

  A cold/expired `:wg` blend fetch is expensive: it may serially dispatch
  up to ~10 constituent requests at `HTTPAdapter`'s fetch-spacing interval,
  each bounded by its own connect/receive timeouts -- tens of seconds
  worst case. That's within `get/4`'s 30s call budget, but far past what
  the watch (which abandons a request after 5s) can wait on, and it would
  otherwise stall this GenServer's mailbox (including the STATION leg of
  the very same request, and every other caller) for the duration.

  So, unlike the station leg (a single fast fetch, still synchronous), the
  FORECAST leg never blocks `handle_call` on a live fetch:

    * When the forecast entry is missing, expired, moved beyond
      `@move_invalidate_km`, or its recorded `requested` descriptor no
      longer matches the request, `get/4` immediately replies with
      whatever it already has -- the last-good entry, or
      `{:error, :no_data}` if there isn't one yet -- and kicks off an
      async refresh (a `Task.Supervisor`-supervised task; see
      `Stallalert.TaskSupervisor` in `Stallalert.Application`).
    * Overlapping refreshes for the *exact same* `{pos, requested}` target
      are deduplicated via a single `forecast_inflight` marker in state
      (ref + target): a second `get/4` that lands while a matching refresh
      is already running does not start another one.
    * A request for a *different* target (position or model descriptor
      changed) while a refresh is in flight starts a new task and replaces
      `forecast_inflight` with its ref -- the old task keeps running (it
      is not killed), but its eventual completion no longer matches the
      tracked ref, so `handle_info/2` discards it as stale instead of
      clobbering the newer target's cache slot with old data.

  Net effect: the very first request ever made (empty cache) still gets
  `{:error, :no_data}` -- exactly today's cold-boot behavior, which the
  watch already handles by fast-retrying every 10s -- and every request
  after that serves cached data immediately while refreshing in the
  background. The existing TTL+grace staleness logic is unchanged: a
  background-refreshing entry is served as last-good with an honest
  `stale` flag for however old it actually is.

  The background `:refresh` tick re-fetches for the last *requested*
  position, `station_id`, AND `model`, so an active override keeps being
  honored by background refreshes rather than silently reverting between
  client polls.
  """
  use GenServer

  @forecast_ttl_ms 15 * 60 * 1000
  @station_ttl_ms 5 * 60 * 1000
  @grace_ms 10 * 60 * 1000
  # A cached entry is treated as expired (and re-fetched) if the rider has
  # moved more than this many km since it was fetched, even if its TTL
  # hasn't elapsed -- otherwise a request for a new position within TTL
  # would silently serve the old position's forecast/station as `stale: false`.
  # It also doubles as the "did the request move on while a forecast refresh
  # was in flight" threshold -- see the moduledoc's async section.
  @move_invalidate_km 2.0

  # Client

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  # Worst-case sequential chain on a cache miss: the STATION leg (list +
  # reading, 2 legs) is the only synchronous work left in this call -- each
  # bounded by http_adapter.ex's Req timeouts (connect 2.5s + receive 3.5s
  # = 6s per leg) => 2 * 6s = 12s < 30s. The FORECAST leg never blocks this
  # call; see the moduledoc.
  #
  # `opts[:station_id]`, when present, requests that specific station
  # instead of the nearest one -- see the moduledoc for override semantics.
  # `opts[:model]`, when present, requests that forecast model instead of
  # the WG-blend -- same override semantics, forecast side.
  def get(server \\ __MODULE__, lat, lon, opts \\ []) do
    GenServer.call(server, {:get, lat, lon, opts[:station_id], opts[:model]}, 30_000)
  end

  # Server

  @impl true
  def init(opts) do
    refresh? = Keyword.get(opts, :refresh, true)
    forecast_ttl_ms = Keyword.get(opts, :forecast_ttl_ms, @forecast_ttl_ms)
    station_ttl_ms = Keyword.get(opts, :station_ttl_ms, @station_ttl_ms)
    grace_ms = Keyword.get(opts, :grace_ms, @grace_ms)
    if refresh?, do: Process.send_after(self(), :refresh, @station_ttl_ms)

    {:ok,
     %{
       pos: nil,
       station_id: nil,
       model_req: "wg",
       forecast: nil,
       forecast_inflight: nil,
       station: nil,
       refresh?: refresh?,
       forecast_ttl_ms: forecast_ttl_ms,
       station_ttl_ms: station_ttl_ms,
       grace_ms: grace_ms
     }}
  end

  @impl true
  def handle_call({:get, lat, lon, station_id, model}, _from, state) do
    adapter = Application.fetch_env!(:stallalert, :windguru_adapter)
    model_req = model || "wg"
    state = %{state | pos: {lat, lon}, station_id: station_id, model_req: model_req}
    state = maybe_refresh(state, now_ms())

    nearby =
      case adapter.stations_near(lat, lon, 6) do
        {:ok, list} -> list
        {:error, _} -> []
      end

    available_models =
      case adapter.available_models(lat, lon) do
        {:ok, list} -> list
        {:error, _} -> []
      end

    case build_payload(state, nearby, available_models) do
      nil -> {:reply, {:error, :no_data}, state}
      payload -> {:reply, {:ok, payload}, state}
    end
  end

  @impl true
  def handle_info(:refresh, %{pos: nil} = state) do
    reschedule(state)
    {:noreply, state}
  end

  def handle_info(:refresh, state) do
    state = maybe_refresh(state, now_ms())
    reschedule(state)
    {:noreply, state}
  end

  # Forecast task completion: only applied when it matches the currently
  # tracked in-flight target (guards against a ref left over from a
  # previous, already-superseded fetch -- see `start_forecast_refresh/3`).
  def handle_info({ref, result}, %{forecast_inflight: %{ref: ref} = inflight} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{apply_forecast_result(state, inflight, result) | forecast_inflight: nil}}
  end

  # A stray task completion (already superseded by a newer in-flight target)
  # -- discard, but still demonitor so the matching :DOWN doesn't also
  # arrive and need handling.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{forecast_inflight: %{ref: ref}} = state
      ) do
    # The refresh task crashed instead of returning a result; drop tracking
    # so the next request (or the next :refresh tick) can retry.
    {:noreply, %{state | forecast_inflight: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp reschedule(%{refresh?: true}), do: Process.send_after(self(), :refresh, @station_ttl_ms)
  defp reschedule(_), do: :ok

  defp maybe_refresh(
         %{pos: pos, station_id: station_id, model_req: model_req} = state,
         now
       ) do
    adapter = Application.fetch_env!(:stallalert, :windguru_adapter)

    state = maybe_refresh_forecast(state, adapter, pos, model_req, now)

    station =
      refresh_station_entry(state.station, state.station_ttl_ms, now, pos, station_id, adapter)

    %{state | station: station}
  end

  # forecast entry: %{data: term, fetched_at: ms, pos: {lat, lon},
  #                   requested: "wg" | "52" | ...} | nil
  #
  # Mirrors the station entry's `requested` philosophy: the verbatim
  # requested-model descriptor is recorded so identical repeats stay
  # cache-stable while a switch invalidates immediately. Unlike the station
  # leg, a stale/missing/mismatched entry never blocks this call on a live
  # fetch -- see the moduledoc's async section. The current entry (possibly
  # nil, possibly stale) is always kept as-is here; only a completed async
  # task (see `handle_info/2` above) ever replaces it.
  defp maybe_refresh_forecast(state, adapter, pos, model_req, now) do
    entry = state.forecast

    fresh? =
      entry != nil and entry.requested == model_req and
        now - entry.fetched_at < state.forecast_ttl_ms and
        Stallalert.Geo.distance_km(entry.pos, pos) <= @move_invalidate_km

    cond do
      fresh? -> state
      inflight_matches?(state.forecast_inflight, pos, model_req) -> state
      true -> start_forecast_refresh(state, adapter, pos, model_req)
    end
  end

  # Deliberately exact-match (not the `fresh?` distance fuzziness above):
  # this only governs whether a second `get/4` landing *during the brief
  # window a fetch is already running* piggybacks on it instead of starting
  # a redundant one. A real GPS position essentially never repeats
  # bit-for-bit between polls anyway, so exact match doesn't cost dedup
  # coverage in practice -- normal within-TTL repeats are already served
  # from the cached entry via `fresh?` without ever reaching this check.
  defp inflight_matches?(nil, _pos, _model_req), do: false

  defp inflight_matches?(%{pos: pos, requested: model_req}, pos, model_req), do: true

  defp inflight_matches?(_inflight, _pos, _model_req), do: false

  # Dispatches the live fetch on a supervised, unlinked task so a slow/cold
  # WG-blend can never stall this GenServer's mailbox. The task sends its
  # result back as a plain `{ref, result}` message (standard `Task` async
  # protocol); `handle_info/2` above only applies it if `forecast_inflight`
  # still points at this same ref by the time it arrives.
  defp start_forecast_refresh(state, adapter, pos, model_req) do
    {lat, lon} = pos
    model_arg = model_arg(model_req)

    task =
      Task.Supervisor.async_nolink(Stallalert.TaskSupervisor, fn ->
        adapter.forecast(lat, lon, model_arg)
      end)

    %{state | forecast_inflight: %{ref: task.ref, pos: pos, requested: model_req}}
  end

  defp model_arg("wg"), do: :wg

  defp model_arg(descriptor) do
    case Integer.parse(descriptor) do
      {int, ""} -> int
      _ -> :wg
    end
  end

  # No separate "is this completion stale" check is needed here: by the
  # time `handle_info/2` above lets a completion reach this function, its
  # ref has already been proven to be the CURRENT `forecast_inflight`
  # target. Any request that moved on (different position or model
  # descriptor) while this fetch was running would have replaced
  # `forecast_inflight` with a fresh ref for the new target *before* this
  # one could arrive (see `maybe_refresh_forecast/5` /
  # `start_forecast_refresh/4`) -- so a stale completion always fails the
  # ref match in `handle_info/2` and is discarded there, never reaching
  # here.
  defp apply_forecast_result(state, inflight, {:ok, data}) do
    %{
      state
      | forecast: %{
          data: data,
          fetched_at: now_ms(),
          pos: inflight.pos,
          requested: inflight.requested
        }
    }
  end

  defp apply_forecast_result(state, _inflight, {:error, _reason}), do: state

  # station entry: %{data: term, fetched_at: ms, pos: {lat, lon},
  #                   target_id: integer | nil, source: "auto" | "manual",
  #                   requested: integer | :auto} | nil
  #
  # When a station entry is fetched, we record the verbatim request descriptor
  # (`station_id || :auto`) in the `requested` field. This ensures that identical
  # requests (including rejected overrides that fall back to auto) remain
  # cache-stable within TTL, while any change of request descriptor invalidates
  # the entry immediately. For example: a rejected override (unknown station id)
  # falls back to auto with `source: "auto"`, but we record the original
  # (rejected) station_id in `requested`, so a repeated identical request matches
  # and serves the cached data without re-fetching; switching to a different
  # override or dropping the override altogether causes a mismatch in `requested`
  # and forces a refresh. On adapter error while resolving, the existing entry
  # is kept -- same philosophy as any other fetch failure: never drop last-good
  # data.
  defp refresh_station_entry(entry, ttl, now, pos, station_id, adapter) do
    requested_key = station_id || :auto

    fresh? =
      entry != nil and requested_key == entry.requested and
        now - entry.fetched_at < ttl and
        Stallalert.Geo.distance_km(entry.pos, pos) <= @move_invalidate_km

    if fresh? do
      entry
    else
      {lat, lon} = pos

      case fetch_station(adapter, lat, lon, station_id) do
        {:ok, target_id, source, data} ->
          %{
            data: data,
            fetched_at: now,
            pos: pos,
            target_id: target_id,
            source: source,
            requested: requested_key
          }

        {:error, _} ->
          entry
      end
    end
  end

  defp fetch_station(adapter, lat, lon, nil), do: fetch_auto_station(adapter, lat, lon)

  defp fetch_station(adapter, lat, lon, station_id) do
    case adapter.station_by_id(station_id, lat, lon) do
      # Unknown/out-of-range override: fall back to auto-nearest.
      {:ok, nil} -> fetch_auto_station(adapter, lat, lon)
      {:ok, info} -> with_reading(adapter, info, "manual")
      {:error, _} = error -> error
    end
  end

  defp fetch_auto_station(adapter, lat, lon) do
    case adapter.nearest_station(lat, lon) do
      {:ok, nil} -> {:ok, nil, "auto", nil}
      {:ok, info} -> with_reading(adapter, info, "auto")
      {:error, _} = error -> error
    end
  end

  defp with_reading(adapter, info, source) do
    case adapter.station_reading(info.id) do
      {:ok, reading} -> {:ok, info.id, source, Map.put(info, :reading, reading)}
      {:error, _} = error -> error
    end
  end

  defp build_payload(%{forecast: nil}, _nearby, _available_models), do: nil

  defp build_payload(state, nearby, available_models) do
    now = now_ms()

    forecast_stale? =
      now - state.forecast.fetched_at > state.forecast_ttl_ms + state.grace_ms

    station_stale? =
      state.station != nil and state.station.data != nil and
        now - state.station.fetched_at > state.station_ttl_ms + state.grace_ms

    station =
      state.station && state.station.data &&
        Map.put(state.station.data, :source, state.station.source)

    %{
      generated_at: DateTime.utc_now(),
      stale: forecast_stale? or station_stale?,
      forecast: state.forecast.data,
      station: station,
      nearby_stations: nearby,
      requested_model: state.model_req,
      available_models: available_models
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
