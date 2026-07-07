defmodule Stallalert.Windguru.MicroParserTest do
  use ExUnit.Case, async: true
  alias Stallalert.Windguru.MicroParser

  @fixture "test/fixtures/windguru/micro_forecast.txt" |> File.read!()

  describe "real captured fixture (HTML page with a <pre>-formatted table)" do
    test "parses into a normalized, ascending timeline" do
      assert {:ok, f} = MicroParser.parse(@fixture)
      assert f.model == "gfs-micro"
      assert f.init_time == ~U[2026-07-06 18:00:00Z]
      assert length(f.hours) == 179
      assert f.hours == Enum.sort_by(f.hours, & &1.time, DateTime)

      [first, second | _] = f.hours
      # exact values read manually from test/fixtures/windguru/micro_forecast.txt
      # row: "  Mon 6. 18h       2       4     ESE     122 ..."
      assert first.time == ~U[2026-07-06 18:00:00Z]
      assert first.wind_kn == 2.0
      assert first.gust_kn == 4.0
      assert first.dir_deg == 122.0

      # row: "  Mon 6. 19h       3       2     ENE      67 ..."
      assert second.time == ~U[2026-07-06 19:00:00Z]
      assert second.wind_kn == 3.0
      assert second.gust_kn == 2.0
      assert second.dir_deg == 67.0

      # a later 3-hourly row, still within the same month:
      # " Fri 10. 00h       9      10     SSW     194 ..."
      later = Enum.find(f.hours, &(&1.time == ~U[2026-07-10 00:00:00Z]))
      assert later.wind_kn == 9.0
      assert later.gust_kn == 10.0
      assert later.dir_deg == 194.0
    end
  end

  describe "month rollover" do
    test "bumps month (and year across December) when the day-of-month number decreases" do
      text = """
      <html><body><pre>
      GFS 13 km (init: 2026-12-31 18 UTC)

              Date    WSPD    GUST   WDIRN    WDEG     TMP     SLP    HCLD    MCLD    LCLD    APCP   APCP1      RH
           (UTC+0)   knots   knots    dir.    deg.       C     hPa       %       %       %   mm/3h   mm/1h       %

        Wed 31. 22h       2       4     ESE     122      28    1018       -       -       -       -       -      55
        Wed 31. 23h       3       2     ENE      67      28    1018       0       0       0       -       0      58
        Thu 1. 00h       4       6     WSW     239      27    1018       0       0       0       -       0      60
        Thu 1. 01h       4       6     WSW     256      27    1018       0       0       0       -       0      59
      </pre></body></html>
      """

      assert {:ok, f} = MicroParser.parse(text)
      assert length(f.hours) == 4
      times = Enum.map(f.hours, & &1.time)

      assert times == [
               ~U[2026-12-31 22:00:00Z],
               ~U[2026-12-31 23:00:00Z],
               ~U[2027-01-01 00:00:00Z],
               ~U[2027-01-01 01:00:00Z]
             ]
    end
  end

  describe "garbage/empty rejection" do
    test "rejects a plain HTML page with no <pre> table" do
      assert {:error, :unexpected_format} = MicroParser.parse("<html>nope</html>")
    end

    test "rejects an empty string" do
      assert {:error, :unexpected_format} = MicroParser.parse("")
    end

    test "rejects a <pre> block with no init line" do
      assert {:error, :unexpected_format} = MicroParser.parse("<pre>nothing useful here</pre>")
    end
  end

  describe "fewer than 3 timesteps" do
    test "rejects when only 2 rows parse" do
      text = """
      <pre>
      GFS 13 km (init: 2026-07-06 18 UTC)

              Date    WSPD    GUST   WDIRN    WDEG     TMP     SLP    HCLD    MCLD    LCLD    APCP   APCP1      RH
           (UTC+0)   knots   knots    dir.    deg.       C     hPa       %       %       %   mm/3h   mm/1h       %

        Mon 6. 18h       2       4     ESE     122      28    1018       -       -       -       -       -      55
        Mon 6. 19h       3       2     ENE      67      28    1018       0       0       0       -       0      58
      </pre>
      """

      assert {:error, :unexpected_format} = MicroParser.parse(text)
    end
  end
end
