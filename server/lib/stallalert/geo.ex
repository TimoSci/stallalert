defmodule Stallalert.Geo do
  @moduledoc """
  Haversine great-circle distance and nearest-station selection.

  Used to pick the live windguru station closest to a subscription's
  lat/lon, capped at `@max_station_km` — beyond that a "nearby" station
  reading is not representative of the subscriber's actual conditions,
  so callers should fall back to forecast-only data instead.
  """

  @earth_radius_km 6371.0
  @max_station_km 30.0

  @type coord :: {lat :: float, lon :: float}
  @type station :: %{optional(any) => any, id: integer, name: String.t(), lat: float, lon: float}

  @doc "Great-circle distance between two `{lat, lon}` points, in kilometers."
  @spec distance_km(coord, coord) :: float
  def distance_km({lat1, lon1}, {lat2, lon2}) do
    dlat = deg2rad(lat2 - lat1)
    dlon = deg2rad(lon2 - lon1)

    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(deg2rad(lat1)) * :math.cos(deg2rad(lat2)) * :math.sin(dlon / 2) ** 2

    2 * @earth_radius_km * :math.asin(:math.sqrt(a))
  end

  @doc """
  Picks the closest station to `pos` from `stations`.

  Returns `{station, distance_km}`, or `nil` if `stations` is empty or
  the nearest one is farther than #{@max_station_km} km away.
  """
  @spec nearest([station], coord) :: {station, float} | nil
  def nearest([], _pos), do: nil

  def nearest(stations, pos) do
    {station, d} =
      stations
      |> Enum.map(&{&1, distance_km({&1.lat, &1.lon}, pos)})
      |> Enum.min_by(fn {_s, d} -> d end)

    if d <= @max_station_km, do: {station, d}, else: nil
  end

  defp deg2rad(deg), do: deg * :math.pi() / 180
end
