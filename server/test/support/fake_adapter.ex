defmodule Stallalert.FakeAdapter do
  @behaviour Stallalert.Windguru.Adapter
  # Test process registers responses; defaults are healthy values.
  def set(key, value), do: :persistent_term.put({__MODULE__, key}, value)
  defp get_resp(key, default), do: :persistent_term.get({__MODULE__, key}, default)

  @impl true
  def forecast(_lat, _lon) do
    get_resp(
      :forecast,
      {:ok,
       %{
         model: "wg",
         init_time: ~U[2026-07-06 06:00:00Z],
         hours: [%{time: ~U[2026-07-06 10:00:00Z], wind_kn: 14.0, gust_kn: 21.0, dir_deg: 225.0}]
       }}
    )
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
