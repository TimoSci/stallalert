defmodule Stallalert.GeoTest do
  use ExUnit.Case, async: true
  alias Stallalert.Geo

  test "haversine distance Amsterdam->Utrecht ~= 35 km" do
    d = Geo.distance_km({52.37, 4.90}, {52.09, 5.12})
    assert_in_delta d, 35.0, 2.0
  end

  test "nearest picks closest station and reports distance" do
    stations = [
      %{id: 1, name: "far", lat: 53.0, lon: 6.0},
      %{id: 2, name: "near", lat: 52.38, lon: 4.92}
    ]

    assert {%{id: 2}, d} = Geo.nearest(stations, {52.37, 4.90})
    assert d < 3.0
  end

  test "nearest returns nil when closest is beyond 30 km" do
    assert nil == Geo.nearest([%{id: 1, name: "far", lat: 55.0, lon: 8.0}], {52.37, 4.90})
  end

  test "nearest returns nil for empty list" do
    assert nil == Geo.nearest([], {52.37, 4.90})
  end
end
