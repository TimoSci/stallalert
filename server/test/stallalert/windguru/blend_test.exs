defmodule Stallalert.Windguru.BlendTest do
  use ExUnit.Case, async: true

  alias Stallalert.Windguru.Blend
  alias Stallalert.Windguru.ForecastParser

  @now ~U[2026-01-01 00:00:00Z]

  defp step(time, wind, gust, dir),
    do: %{time: time, wind_kn: wind * 1.0, gust_kn: gust * 1.0, dir_deg: dir * 1.0}

  defp forecast(model, init_time, hours),
    do: %{model: model, init_time: init_time, hours: hours}

  # Circular distance in degrees -- 359.999... and 0.0 are the same compass
  # point, so plain `assert_in_delta` is the wrong tool near the north seam
  # (floating-point sin(350)+sin(10) lands a hair below zero, not exactly
  # zero, so atan2 returns a tiny negative angle that the +360 normalization
  # rule pushes to ~359.999999999999983 rather than 0.0).
  defp assert_direction_close(expected, actual, delta \\ 0.01) do
    raw = abs(expected - actual)
    raw = :math.fmod(raw, 360.0)
    circular = min(raw, 360.0 - raw)

    assert circular < delta,
           "expected #{actual} to be within #{delta} degrees of #{expected} (circular), got #{circular}"
  end

  describe "weighted mean wind/gust on the common grid" do
    test "arithmetic mean of two hourly models, koef-weighted" do
      a =
        forecast("A", @now, [step(@now, 10, 10, 90), step(DateTime.add(@now, 3600), 10, 10, 90)])

      b =
        forecast("B", @now, [step(@now, 20, 20, 90), step(DateTime.add(@now, 3600), 20, 20, 90)])

      assert {:ok, equal} = Blend.blend([{1, a}, {2, b}], %{1 => 1.0, 2 => 1.0}, @now)
      assert hd(equal.hours).wind_kn == 15.0

      assert {:ok, weighted} = Blend.blend([{1, a}, {2, b}], %{1 => 1.0, 2 => 3.0}, @now)
      assert hd(weighted.hours).wind_kn == 17.5
    end
  end

  describe "direction vector mean crosses the north seam" do
    test "350 and 10 degrees average through north, not through 180" do
      a = forecast("A", @now, [step(@now, 1, 1, 350)])
      b = forecast("B", @now, [step(@now, 1, 1, 10)])

      assert {:ok, equal} = Blend.blend([{1, a}, {2, b}], %{1 => 1.0, 2 => 1.0}, @now)
      assert_direction_close(0.0, hd(equal.hours).dir_deg)

      assert {:ok, weighted} = Blend.blend([{1, a}, {2, b}], %{1 => 3.0, 2 => 1.0}, @now)
      assert_direction_close(355.0, hd(weighted.hours).dir_deg, 0.5)
    end
  end

  describe "within-horizon only: short model stops contributing" do
    test "a model past its own horizon drops out of the grid step" do
      hourly_a = for h <- 0..48, do: step(DateTime.add(@now, h * 3600), 10, 10, 90)
      short_b = for h <- 0..2, do: step(DateTime.add(@now, h * 3600), 20, 20, 90)
      hourly_c = for h <- 0..48, do: step(DateTime.add(@now, h * 3600), 30, 30, 90)

      a = forecast("A", @now, hourly_a)
      b = forecast("B", @now, short_b)
      c = forecast("C", @now, hourly_c)

      koef = %{1 => 1.0, 2 => 1.0, 3 => 1.0}

      assert {:ok, ab} = Blend.blend([{1, a}, {2, b}], koef, @now)
      # only +0h/+1h/+2h have 2 contributors (A+B); later steps drop to a
      # single contributor (A alone) and are dropped entirely.
      assert length(ab.hours) == 3
      assert Enum.all?(ab.hours, &(&1.wind_kn == 15.0))

      assert {:ok, abc} = Blend.blend([{1, a}, {2, b}, {3, c}], koef, @now)
      # full 49-point grid survives: +0h/+1h/+2h blend A+B+C, the rest
      # blend A+C only -- both combinations average to 20.0 here.
      assert length(abc.hours) == 49
      assert Enum.all?(abc.hours, &(&1.wind_kn == 20.0))
    end
  end

  describe "fewer than 2 forecasts" do
    test "returns insufficient_models for zero or one constituent" do
      a = forecast("A", @now, [step(@now, 10, 10, 90)])

      assert {:error, :insufficient_models} = Blend.blend([], %{}, @now)
      assert {:error, :insufficient_models} = Blend.blend([{1, a}], %{1 => 1.0}, @now)
    end
  end

  describe "zero-magnitude vector falls back to highest-weight model's direction" do
    test "opposite directions at equal weight cancel; fall back deterministically" do
      a = forecast("A", @now, [step(@now, 1, 1, 0)])
      b = forecast("B", @now, [step(@now, 1, 1, 180)])

      # equal koef -> tie -> lowest model id (1, model A, dir 0) wins.
      assert {:ok, blended} = Blend.blend([{1, a}, {2, b}], %{1 => 1.0, 2 => 1.0}, @now)
      assert hd(blended.hours).dir_deg == 0.0
    end
  end

  describe "model label counts contributors" do
    test "labels the output with the number of input forecasts" do
      a = forecast("A", @now, [step(@now, 10, 10, 90)])
      b = forecast("B", @now, [step(@now, 20, 20, 90)])
      c = forecast("C", @now, [step(@now, 30, 30, 90)])

      koef = %{1 => 1.0, 2 => 1.0, 3 => 1.0}
      assert {:ok, blended} = Blend.blend([{1, a}, {2, b}, {3, c}], koef, @now)
      assert blended.model == "WG blend (3 models)"
    end
  end

  describe "interpolation between non-hourly steps" do
    test "linearly interpolates a model's own 3-hourly steps onto the hourly grid" do
      # Two identical 3-hourly models -- averaging them together must not
      # perturb the interpolated value, isolating the per-model
      # interpolation math from the cross-model weighting math.
      hours = [step(@now, 12, 12, 90), step(DateTime.add(@now, 3 * 3600), 18, 18, 90)]
      a = forecast("A", @now, hours)
      b = forecast("B", @now, hours)

      assert {:ok, blended} = Blend.blend([{1, a}, {2, b}], %{1 => 1.0, 2 => 1.0}, @now)
      [h0, h1, h2 | _] = blended.hours

      assert h0.wind_kn == 12.0
      assert h1.wind_kn == 14.0
      assert h2.wind_kn == 16.0
    end
  end

  describe "fixture-based end-to-end" do
    # WG blend snapshot values (constituents 3/117/52, koef all 1.0), per
    # server/lib/stallalert/windguru/blend_config.ex's "koef snapshot
    # 2026-07-10" moduledoc.
    @koef %{3 => 1.0, 117 => 1.0, 52 => 1.0}

    # 2026-07-09T16:00:00Z lands on an exact hourly grid point for all
    # three fixtures: forecast_custom inits 2026-07-06T18:00Z (+70h,
    # hourly through ~78h), forecast_m117 inits 2026-07-09T12:00Z (+4h),
    # and forecast_m52 inits 2026-07-09T15:00Z with its first published
    # step at offset 1 (+1h = 16:00Z exactly) -- all three constituents
    # cover the full 49-point grid from here with no extrapolation.
    @now ~U[2026-07-09 16:00:00Z]

    defp parse_fixture!(name) do
      path = Path.join([__DIR__, "..", "..", "fixtures", "windguru", name])
      {:ok, forecast} = path |> File.read!() |> Jason.decode!() |> ForecastParser.parse()
      forecast
    end

    test "blends the three real WG constituent fixtures" do
      custom = parse_fixture!("forecast_custom.json")
      m117 = parse_fixture!("forecast_m117.json")
      m52 = parse_fixture!("forecast_m52.json")

      assert {:ok, blended} =
               Blend.blend([{3, custom}, {117, m117}, {52, m52}], @koef, @now)

      assert blended.model == "WG blend (3 models)"
      assert length(blended.hours) == 49
      assert blended.init_time == m52.init_time

      first = hd(blended.hours)
      assert first.time == @now

      # Exact values read manually from the fixtures at each model's
      # matching hourly offset for @now (no interpolation needed, all
      # three land on an exact step -- see the @now comment above):
      #   forecast_custom @+70h: wind 7.6, dir 71
      #   forecast_m117   @+4h:  wind 4.1, dir 72
      #   forecast_m52    @+1h:  wind 6.4, dir 101
      constituent_winds = [7.6, 4.1, 6.4]
      assert first.wind_kn >= Enum.min(constituent_winds)
      assert first.wind_kn <= Enum.max(constituent_winds)

      constituent_dirs = [71.0, 72.0, 101.0]
      assert first.dir_deg >= Enum.min(constituent_dirs)
      assert first.dir_deg <= Enum.max(constituent_dirs)
    end
  end
end
