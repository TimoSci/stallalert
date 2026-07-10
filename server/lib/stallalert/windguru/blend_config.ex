defmodule Stallalert.Windguru.BlendConfig do
  @moduledoc """
  Tracks Windguru's "WG" blend tab (`id_model=100`) constituent models and
  their per-model koef weights, refreshed periodically from the live
  `q=forecast_spot` endpoint with a hardcoded snapshot fallback.

  `weights/0` never blocks on network I/O: the initial fetch happens
  asynchronously after `init/1` returns (so a slow/failing Windguru never
  delays application startup), and any adapter error or malformed response
  simply keeps serving the last successful fetch (or, before any fetch has
  succeeded, the hardcoded snapshot below). Results are cached in
  `:persistent_term` rather than GenServer state so `weights/0` reads never
  hit the GenServer's mailbox.

  ## Snapshot

  Captured 2026-07-10 by `server/scripts/capture_fixtures.sh` (see its
  "koef snapshot" comment) from `server/test/fixtures/windguru/
  forecast_spot.json`, tabs[0] (the WG tab, `id_model=100`, spot 1189718):

    * `id_model_wave: 84` (wave model, excluded from the wind blend)
    * `id_model_arr`: 3, 117, 52, 107, 104, 64, 21, 43, 45, 59, 84 -- the
      full constituent list, including regional models not necessarily
      servable at every custom lat/lon (per-location pruning is a separate
      concern, layered on top of this module's output).
    * `blend.model_koef`: all listed ids -> 1.0, except 45 -> 0.9 and
      59 -> 0.7.
  """

  use GenServer

  require Logger

  @refresh_interval_ms 24 * 60 * 60 * 1000
  @persistent_term_key {__MODULE__, :weights}
  @default_spot_id 1_189_718

  @snapshot %{
    constituents: [3, 117, 52, 107, 104, 64, 21, 43, 45, 59],
    koef: %{
      3 => 1.0,
      117 => 1.0,
      52 => 1.0,
      107 => 1.0,
      104 => 1.0,
      64 => 1.0,
      21 => 1.0,
      43 => 1.0,
      45 => 0.9,
      59 => 0.7
    }
  }

  # Client

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  The last successfully fetched WG-blend constituents and koef weights
  (wave model excluded), or the hardcoded snapshot if no fetch has
  succeeded yet.
  """
  def weights, do: :persistent_term.get(@persistent_term_key, @snapshot)

  @doc false
  # Test-only escape hatch so the live-fetched cache doesn't leak state
  # between tests (or between a stale run and a fresh one). Clears the GLOBAL
  # persistent_term key shared with the app-supervised singleton. Test files
  # using it revert the singleton to the snapshot for the rest of the suite —
  # acceptable while only blend code reads weights(), but downstream test files
  # depending on weights() must seed their own state in setup rather than
  # assume the singleton's fetch.
  def clear_cache, do: :persistent_term.erase(@persistent_term_key)

  # Server

  @impl true
  def init(opts) do
    refresh? = Keyword.get(opts, :refresh, true)
    spot_id = Keyword.get(opts, :spot_id, default_spot_id())

    # Kick off the initial fetch asynchronously -- never block init/1 (and
    # therefore application startup) on a Windguru round-trip. `weights/0`
    # serves the snapshot (or previous fetch) until this completes.
    if refresh?, do: send(self(), :refresh)

    {:ok, %{spot_id: spot_id, refresh?: refresh?}}
  end

  @impl true
  def handle_info(:refresh, state) do
    adapter = Application.fetch_env!(:stallalert, :windguru_adapter)
    fetch_and_store(state.spot_id, adapter)
    reschedule(state)
    {:noreply, state}
  end

  defp reschedule(%{refresh?: true}),
    do: Process.send_after(self(), :refresh, @refresh_interval_ms)

  defp reschedule(_), do: :ok

  defp default_spot_id do
    case System.get_env("WG_SPOT_ID") do
      nil -> @default_spot_id
      "" -> @default_spot_id
      value -> String.to_integer(value)
    end
  end

  defp fetch_and_store(spot_id, adapter) do
    case adapter.spot_config(spot_id) do
      {:ok, body} ->
        store_from_body(body)

      {:error, reason} ->
        Logger.warning(
          "BlendConfig: spot_config fetch failed (#{inspect(reason)}); keeping previous weights"
        )
    end
  end

  defp store_from_body(body) do
    case find_wg_tab(body) do
      nil ->
        Logger.warning(
          "BlendConfig: no WG tab (id_model=100) found in spot_config response; keeping previous weights"
        )

      tab ->
        case extract_weights(tab) do
          {:ok, weights} ->
            :persistent_term.put(@persistent_term_key, weights)

          :error ->
            Logger.warning(
              "BlendConfig: malformed id_model=100 tab in spot_config response; keeping previous weights"
            )
        end
    end
  end

  defp find_wg_tab(%{"tabs" => tabs}) when is_list(tabs) do
    Enum.find(tabs, fn tab -> is_map(tab) and tab["id_model"] == 100 end)
  end

  defp find_wg_tab(_body), do: nil

  defp extract_weights(%{"id_model_arr" => arr} = tab) when is_list(arr) do
    wave = Map.get(tab, "id_model_wave")
    koef = get_in(tab, ["blend", "model_koef"]) || %{}

    constituents =
      arr
      |> Enum.map(fn entry -> is_map(entry) && Map.get(entry, "id_model") end)
      |> Enum.filter(&is_integer/1)
      |> Enum.reject(&(&1 == wave))

    koef_map =
      Map.new(constituents, fn id ->
        weight = Map.get(koef, Integer.to_string(id), 1.0)
        {id, weight * 1.0}
      end)

    {:ok, %{constituents: constituents, koef: koef_map}}
  end

  defp extract_weights(_tab), do: :error
end
