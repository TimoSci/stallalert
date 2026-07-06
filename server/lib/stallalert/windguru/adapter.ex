defmodule Stallalert.Windguru.Adapter do
  @callback forecast(lat :: float, lon :: float) :: {:ok, map} | {:error, term}
  @callback nearest_station(lat :: float, lon :: float) ::
              {:ok, %{id: integer, name: String.t(), distance_km: float}}
              | {:ok, nil}
              | {:error, term}
  @callback station_reading(id :: integer) :: {:ok, map} | {:error, term}
end
