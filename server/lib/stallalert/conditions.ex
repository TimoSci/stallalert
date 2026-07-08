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

  The background `:refresh` tick re-fetches for the last *requested*
  position AND the last requested `station_id`, so an active override
  keeps being honored by background refreshes rather than silently
  reverting to auto between client polls.
  """
  use GenServer

  @forecast_ttl_ms 15 * 60 * 1000
  @station_ttl_ms 5 * 60 * 1000
  @grace_ms 10 * 60 * 1000
  # A cached entry is treated as expired (and re-fetched) if the rider has
  # moved more than this many km since it was fetched, even if its TTL
  # hasn't elapsed -- otherwise a request for a new position within TTL
  # would silently serve the old position's forecast/station as `stale: false`.
  @move_invalidate_km 2.0

  # Client

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  # Worst-case sequential chain on a cache miss: forecast iapi (fail-slow)
  # + micro fallback, then station list + station reading -- 4 legs, each
  # bounded by http_adapter.ex's Req timeouts (connect 2.5s + receive 3.5s
  # = 6s per leg) => 4 * 6s = 24s < 30s.
  #
  # `opts[:station_id]`, when present, requests that specific station
  # instead of the nearest one -- see the moduledoc for override semantics.
  def get(server \\ __MODULE__, lat, lon, opts \\ []) do
    GenServer.call(server, {:get, lat, lon, opts[:station_id]}, 30_000)
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
       forecast: nil,
       station: nil,
       refresh?: refresh?,
       forecast_ttl_ms: forecast_ttl_ms,
       station_ttl_ms: station_ttl_ms,
       grace_ms: grace_ms
     }}
  end

  @impl true
  def handle_call({:get, lat, lon, station_id}, _from, state) do
    adapter = Application.fetch_env!(:stallalert, :windguru_adapter)
    state = %{state | pos: {lat, lon}, station_id: station_id}
    state = maybe_refresh(state, now_ms())

    nearby =
      case adapter.stations_near(lat, lon, 6) do
        {:ok, list} -> list
        {:error, _} -> []
      end

    case build_payload(state, nearby) do
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

  defp reschedule(%{refresh?: true}), do: Process.send_after(self(), :refresh, @station_ttl_ms)
  defp reschedule(_), do: :ok

  defp maybe_refresh(%{pos: {lat, lon} = pos, station_id: station_id} = state, now) do
    adapter = Application.fetch_env!(:stallalert, :windguru_adapter)

    forecast =
      refresh_entry(state.forecast, state.forecast_ttl_ms, now, pos, fn ->
        adapter.forecast(lat, lon)
      end)

    station =
      refresh_station_entry(state.station, state.station_ttl_ms, now, pos, station_id, adapter)

    %{state | forecast: forecast, station: station}
  end

  # entry: %{data: term, fetched_at: ms, pos: {lat, lon}} | nil
  defp refresh_entry(entry, ttl, now, pos, fetch_fun) do
    fresh? =
      entry != nil and now - entry.fetched_at < ttl and
        Stallalert.Geo.distance_km(entry.pos, pos) <= @move_invalidate_km

    if fresh? do
      entry
    else
      case fetch_fun.() do
        {:ok, data} -> %{data: data, fetched_at: now, pos: pos}
        {:error, _} -> entry
      end
    end
  end

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

  defp build_payload(%{forecast: nil}, _nearby), do: nil

  defp build_payload(state, nearby) do
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
      nearby_stations: nearby
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
