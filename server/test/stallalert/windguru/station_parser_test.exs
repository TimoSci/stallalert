defmodule Stallalert.Windguru.StationParserTest do
  use ExUnit.Case, async: true
  alias Stallalert.Windguru.StationParser

  @reading "test/fixtures/windguru/station_current.json" |> File.read!() |> Jason.decode!()
  @list "test/fixtures/windguru/stations_list.json" |> File.read!() |> Jason.decode!()

  describe "parse_reading/1 (q=station_data time-windowed series)" do
    test "parses the latest sample out of the fixture's window" do
      assert {:ok, r} = StationParser.parse_reading(@reading)
      assert %DateTime{} = r.time

      # exact values read manually from test/fixtures/windguru/station_current.json:
      # the last element of each parallel array is the latest sample.
      # unixtime 1783398300 is UTC 04:25:00 (tzoffset 7200 puts the local
      # "datetime" display string, "2026-07-07 06:25:00", two hours ahead).
      assert r.time == ~U[2026-07-07 04:25:00Z]
      assert r.wind_kn == 0.1
      assert r.gust_kn == 0.5
      assert r.dir_deg == 148.0
    end

    test "rejects an empty window" do
      payload = %{
        "unixtime" => [],
        "wind_avg" => [],
        "wind_max" => [],
        "wind_direction" => []
      }

      assert {:error, :unexpected_format} = StationParser.parse_reading(payload)
    end

    test "rejects a window whose wind fields are all null (silent station)" do
      payload = %{
        "unixtime" => [1_700_000_000, 1_700_000_300],
        "wind_avg" => [nil, nil],
        "wind_max" => [nil, nil],
        "wind_direction" => [nil, nil]
      }

      assert {:error, :unexpected_format} = StationParser.parse_reading(payload)
    end

    test "picks the sample with the greatest unixtime, not just the last array index" do
      # out-of-order window: index 0 has the greatest unixtime
      payload = %{
        "unixtime" => [1_700_000_600, 1_700_000_000, 1_700_000_300],
        "wind_avg" => [9.9, 1.0, 2.0],
        "wind_max" => [12.0, 1.5, 2.5],
        "wind_direction" => [270, 100, 200]
      }

      assert {:ok, r} = StationParser.parse_reading(payload)
      assert r.time == DateTime.from_unix!(1_700_000_600)
      assert r.wind_kn == 9.9
      assert r.gust_kn == 12.0
      assert r.dir_deg == 270.0
    end

    test "rejects unexpected shapes" do
      assert {:error, :unexpected_format} = StationParser.parse_reading(%{})
      assert {:error, :unexpected_format} = StationParser.parse_reading(%{"wind_avg" => 5})
    end

    test "rejects unequal-length parallel arrays" do
      # wind_direction has one fewer element (missing the newest sample)
      payload = %{
        "unixtime" => [1_700_000_000, 1_700_000_300, 1_700_000_600],
        "wind_avg" => [1.0, 2.0, 9.9],
        "wind_max" => [1.5, 2.5, 12.0],
        "wind_direction" => [100, 200]
      }

      assert {:error, :unexpected_format} = StationParser.parse_reading(payload)
    end

    test "picks latest fully-populated sample when the newest sample has nil wind values" do
      # unixtime is sorted; index 2 is the newest, but has nil values
      # index 1 is older but fully populated and should be returned
      payload = %{
        "unixtime" => [1_700_000_000, 1_700_000_300, 1_700_000_600],
        "wind_avg" => [1.0, 2.0, nil],
        "wind_max" => [1.5, 2.5, nil],
        "wind_direction" => [100, 200, nil]
      }

      assert {:ok, r} = StationParser.parse_reading(payload)
      assert r.time == DateTime.from_unix!(1_700_000_300)
      assert r.wind_kn == 2.0
      assert r.gust_kn == 2.5
      assert r.dir_deg == 200.0
    end
  end

  describe "parse_station_list/1 (q=station_list array of station objects)" do
    test "parses the fixture's station list" do
      assert {:ok, stations} = StationParser.parse_station_list(@list)
      assert [s | _] = stations
      assert is_integer(s.id) and is_binary(s.name)
      assert is_number(s.lat) and is_number(s.lon)

      # exact values read manually from test/fixtures/windguru/stations_list.json
      # (first entry: id_station 868, name "BUNKER BEACH CLUB")
      assert s.id == 868
      assert s.name == "BUNKER BEACH CLUB"
      assert s.lat == 41.265259
      assert s.lon == 1.981637
    end

    test "falls back to spotname when name is blank, as several fixture entries do" do
      assert {:ok, stations} = StationParser.parse_station_list(@list)
      # id_station 14427 has name: "" and spotname: "Club RC De l´Ebre" in the fixture
      assert %{name: "Club RC De l´Ebre"} = Enum.find(stations, &(&1.id == 14427))
    end

    test "skips entries missing usable id_station/lat/lon rather than failing the list" do
      payload = [
        %{"id_station" => 1, "name" => "Good", "lat" => 1.0, "lon" => 2.0},
        %{"name" => "No id", "lat" => 1.0, "lon" => 2.0},
        %{"id_station" => 3, "name" => "No lat", "lon" => 2.0},
        %{"id_station" => 4, "name" => "No lon", "lat" => 1.0}
      ]

      assert {:ok, [station]} = StationParser.parse_station_list(payload)
      assert station.id == 1
    end

    test "skips an entry when neither name nor spotname is a usable string" do
      payload = [
        %{"id_station" => 1, "name" => "", "spotname" => "", "lat" => 1.0, "lon" => 2.0},
        %{"id_station" => 2, "name" => "Kept", "lat" => 1.0, "lon" => 2.0}
      ]

      assert {:ok, [station]} = StationParser.parse_station_list(payload)
      assert station.id == 2
    end

    test "an empty list normalizes to an empty result, not an error" do
      assert {:ok, []} = StationParser.parse_station_list([])
    end

    test "rejects unexpected shapes" do
      assert {:error, :unexpected_format} = StationParser.parse_station_list(%{"x" => 1})

      assert {:error, :unexpected_format} =
               StationParser.parse_station_list([%{"nothing" => "usable"}])
    end
  end
end
