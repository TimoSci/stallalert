defmodule Stallalert.Conditions do
  @moduledoc """
  Caches normalized windguru data for the last requested position and
  refreshes it in the background (forecast 15 min, station 5 min).
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
  def get(server \\ __MODULE__, lat, lon), do: GenServer.call(server, {:get, lat, lon}, 30_000)

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
       forecast: nil,
       station: nil,
       refresh?: refresh?,
       forecast_ttl_ms: forecast_ttl_ms,
       station_ttl_ms: station_ttl_ms,
       grace_ms: grace_ms
     }}
  end

  @impl true
  def handle_call({:get, lat, lon}, _from, state) do
    state = %{state | pos: {lat, lon}}
    state = maybe_refresh(state, now_ms())

    case build_payload(state) do
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

  defp maybe_refresh(%{pos: {lat, lon} = pos} = state, now) do
    adapter = Application.fetch_env!(:stallalert, :windguru_adapter)

    forecast =
      refresh_entry(state.forecast, state.forecast_ttl_ms, now, pos, fn ->
        adapter.forecast(lat, lon)
      end)

    station =
      refresh_entry(state.station, state.station_ttl_ms, now, pos, fn ->
        case adapter.nearest_station(lat, lon) do
          {:ok, nil} ->
            {:ok, nil}

          {:ok, info} ->
            case adapter.station_reading(info.id) do
              {:ok, reading} -> {:ok, Map.put(info, :reading, reading)}
              {:error, _} = e -> e
            end

          {:error, _} = e ->
            e
        end
      end)

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

  defp build_payload(%{forecast: nil}), do: nil

  defp build_payload(state) do
    now = now_ms()

    forecast_stale? =
      now - state.forecast.fetched_at > state.forecast_ttl_ms + state.grace_ms

    station_stale? =
      state.station != nil and state.station.data != nil and
        now - state.station.fetched_at > state.station_ttl_ms + state.grace_ms

    %{
      generated_at: DateTime.utc_now(),
      stale: forecast_stale? or station_stale?,
      forecast: state.forecast.data,
      station: state.station && state.station.data
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
