defmodule Stallalert.Windguru.ForecastParserTest do
  use ExUnit.Case, async: true
  alias Stallalert.Windguru.ForecastParser

  @spot_fixture "test/fixtures/windguru/forecast.json" |> File.read!() |> Jason.decode!()
  @custom_fixture "test/fixtures/windguru/forecast_custom.json" |> File.read!() |> Jason.decode!()

  describe "spot forecast fixture (fcst-wrapped, with a sibling fcst_land)" do
    test "parses into a normalized, ascending timeline" do
      assert {:ok, f} = ForecastParser.parse(@spot_fixture)
      assert f.model == "GFS 13 km"
      assert f.init_time == ~U[2026-07-06 18:00:00Z]
      assert length(f.hours) == 179
      assert f.hours == Enum.sort_by(f.hours, & &1.time, DateTime)

      [first | _] = f.hours
      assert first.time == ~U[2026-07-06 18:00:00Z]
      # exact values read manually from test/fixtures/windguru/forecast.json
      assert first.wind_kn == 2.4
      assert first.gust_kn == 4.5
      assert first.dir_deg == 111.0
    end
  end

  describe "custom lat/lon forecast fixture (fcst-wrapped, no fcst_land, PRIMARY production payload)" do
    test "parses into a normalized, ascending timeline" do
      assert {:ok, f} = ForecastParser.parse(@custom_fixture)
      assert f.model == "GFS 13 km"
      assert f.init_time == ~U[2026-07-06 18:00:00Z]
      assert length(f.hours) == 179
      assert f.hours == Enum.sort_by(f.hours, & &1.time, DateTime)

      [first | _] = f.hours
      assert first.time == ~U[2026-07-06 18:00:00Z]
      # exact values read manually from test/fixtures/windguru/forecast_custom.json
      assert first.wind_kn == 1.8
      assert first.gust_kn == 3.9
      assert first.dir_deg == 122.0
    end
  end

  describe "unwrapped top-level shape (a body pasted from a browser has this shape)" do
    test "parses identically to the fcst-wrapped equivalent" do
      # Derived directly from the custom fixture's `fcst` payload, un-nested
      # to the top level — same data, no "fcst" wrapper key.
      unwrapped = @custom_fixture["fcst"]

      assert {:ok, wrapped_result} = ForecastParser.parse(@custom_fixture)
      assert {:ok, unwrapped_result} = ForecastParser.parse(unwrapped)

      assert unwrapped_result == wrapped_result
    end
  end

  describe "null-step skipping" do
    test "skips a step when any wind-relevant value is null, keeps the rest" do
      payload = %{
        "initstamp" => 1_700_000_000,
        "model_name" => "Test Model",
        "hours" => [0, 1, 2, 3],
        "WINDSPD" => [10.0, nil, 12.0, 13.0],
        "GUST" => [15.0, 16.0, nil, 18.0],
        "WINDDIR" => [100, 110, 120, nil]
      }

      assert {:ok, f} = ForecastParser.parse(payload)
      # only offset 0 has all three wind values present
      assert length(f.hours) == 1
      assert hd(f.hours).wind_kn == 10.0
      assert hd(f.hours).gust_kn == 15.0
      assert hd(f.hours).dir_deg == 100.0
    end
  end

  describe "length-mismatch rejection" do
    test "rejects when a parallel array's length does not match hours" do
      payload = %{
        "initstamp" => 1_700_000_000,
        "hours" => [0, 1, 2],
        "WINDSPD" => [10.0, 11.0],
        "GUST" => [15.0, 16.0, 17.0],
        "WINDDIR" => [100, 110, 120]
      }

      assert {:error, :unexpected_format} = ForecastParser.parse(payload)
    end
  end

  describe "model defaulting" do
    test "defaults to \"unknown\" when model_name is absent" do
      payload = %{
        "initstamp" => 1_700_000_000,
        "hours" => [0],
        "WINDSPD" => [10.0],
        "GUST" => [15.0],
        "WINDDIR" => [100]
      }

      assert {:ok, f} = ForecastParser.parse(payload)
      assert f.model == "unknown"
    end
  end

  describe "rejects unexpected shapes" do
    test "unrelated map" do
      assert {:error, :unexpected_format} = ForecastParser.parse(%{"foo" => 1})
    end

    test "fcst present but missing initstamp/hours" do
      assert {:error, :unexpected_format} =
               ForecastParser.parse(%{"fcst" => %{"hours" => "nope"}})
    end
  end
end
