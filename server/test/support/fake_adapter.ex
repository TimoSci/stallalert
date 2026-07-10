defmodule Stallalert.FakeAdapter do
  @behaviour Stallalert.Windguru.Adapter

  # Fixture is loaded from the same file capture_fixtures.sh's "koef
  # snapshot" comment was derived from; see
  # Stallalert.Windguru.BlendConfig's module doc for the snapshot values.
  @spot_config_fixture "test/fixtures/windguru/forecast_spot.json"
                       |> File.read!()
                       |> Jason.decode!()

  # Test process registers responses; defaults are healthy values.
  def set(key, value), do: :persistent_term.put({__MODULE__, key}, value)
  defp get_resp(key, default), do: :persistent_term.get({__MODULE__, key}, default)

  def reset do
    :persistent_term.erase({__MODULE__, :forecast})
    :persistent_term.erase({__MODULE__, :nearest_station})
    :persistent_term.erase({__MODULE__, :station_reading})
    :persistent_term.erase({__MODULE__, :stations_near})
    :persistent_term.erase({__MODULE__, :station_by_id})
    :persistent_term.erase({__MODULE__, :spot_config})
    :persistent_term.erase({__MODULE__, :available_models})
    :ok
  end

  @impl true
  def forecast(_lat, _lon, model \\ :wg) do
    get_resp(:forecast, {:ok, default_forecast(model)})
  end

  # Hours are generated relative to "now" (rather than a fixed timestamp) so
  # the router's now-1h..+12-steps trimming always has data to work with,
  # regardless of when the suite runs. `model` is echoed verbatim (as a
  # string) into the `model` field so Conditions/router tests can assert
  # which model was requested (`:wg` -> "wg", `52` -> "52", ...).
  defp default_forecast(model) do
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

    %{model: to_string(model), init_time: DateTime.add(now, -4 * 3600, :second), hours: hours}
  end

  @impl true
  def nearest_station(_lat, _lon) do
    get_resp(:nearest_station, {:ok, %{id: 1, name: "TestStn", distance_km: 1.2}})
  end

  @impl true
  def station_reading(_id) do
    get_resp(
      :station_reading,
      {:ok,
       %{
         time: ~U[2026-07-06 09:55:00Z],
         wind_kn: 15.5,
         gust_kn: 20.1,
         dir_deg: 230.0,
         direction_history: [
           %{time: ~U[2026-07-06 09:45:00Z], dir_deg: 210.0},
           %{time: ~U[2026-07-06 09:50:00Z], dir_deg: 220.0},
           %{time: ~U[2026-07-06 09:55:00Z], dir_deg: 230.0}
         ]
       }}
    )
  end

  @impl true
  def stations_near(_lat, _lon, _limit) do
    get_resp(
      :stations_near,
      {:ok,
       [
         %{id: 1, name: "TestStn", distance_km: 1.2},
         %{id: 2, name: "OtherBeach", distance_km: 4.7}
       ]}
    )
  end

  @impl true
  def station_by_id(id, _lat, _lon) do
    get_resp(:station_by_id, default_station_by_id(id))
  end

  defp default_station_by_id(id) when id in [1, 2, 77] do
    {:ok, %{id: id, name: "Chosen", distance_km: 3.3}}
  end

  defp default_station_by_id(_id), do: {:ok, nil}

  @impl true
  def spot_config(_id_spot) do
    get_resp(:spot_config, {:ok, @spot_config_fixture})
  end

  @impl true
  def available_models(_lat, _lon) do
    get_resp(
      :available_models,
      {:ok,
       [
         %{id: "wg", name: "WG blend"},
         %{id: "52", name: "AROME-FR 1.3 km"},
         %{id: "3", name: "GFS 13 km"}
       ]}
    )
  end
end
