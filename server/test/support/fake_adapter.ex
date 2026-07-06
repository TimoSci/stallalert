defmodule Stallalert.FakeAdapter do
  @behaviour Stallalert.Windguru.Adapter
  # Test process registers responses; defaults are healthy values.
  def set(key, value), do: :persistent_term.put({__MODULE__, key}, value)
  defp get_resp(key, default), do: :persistent_term.get({__MODULE__, key}, default)

  def reset do
    :persistent_term.erase({__MODULE__, :forecast})
    :persistent_term.erase({__MODULE__, :nearest_station})
    :persistent_term.erase({__MODULE__, :station_reading})
    :ok
  end

  @impl true
  def forecast(_lat, _lon) do
    get_resp(:forecast, {:ok, default_forecast()})
  end

  # Hours are generated relative to "now" (rather than a fixed timestamp) so
  # the router's now-1h..+12-steps trimming always has data to work with,
  # regardless of when the suite runs.
  defp default_forecast do
    now = DateTime.utc_now()

    hours =
      for offset <- -2..13 do
        %{
          time: DateTime.add(now, offset * 3600, :second),
          wind_kn: 14.0,
          gust_kn: 21.0,
          dir_deg: 225.0
        }
      end

    %{model: "wg", init_time: DateTime.add(now, -4 * 3600, :second), hours: hours}
  end

  @impl true
  def nearest_station(_lat, _lon) do
    get_resp(:nearest_station, {:ok, %{id: 1, name: "TestStn", distance_km: 1.2}})
  end

  @impl true
  def station_reading(_id) do
    get_resp(
      :station_reading,
      {:ok, %{time: ~U[2026-07-06 09:55:00Z], wind_kn: 15.5, gust_kn: 20.1, dir_deg: 230.0}}
    )
  end
end
