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

  describe "per-model direction interpolation crosses the north seam" do
    test "direction interpolates across the north seam within a single model" do
      # Model A: constant 1 deg on the hourly grid (deliberately *not* 0 --
      # see note below), so it never perturbs the cross-model blend's
      # direction away from whatever B contributes.
      hourly_a = for h <- 0..2, do: step(DateTime.add(@now, h * 3600), 1, 1, 1)
      # Model B: only two raw steps, +0h at 350 deg and +2h at 10 deg -- the
      # grid's +1h point falls exactly at the midpoint between them, so B's
      # own per-model interpolation must go through the seam (0), not
      # through 180, when computing its +1h contribution.
      steps_b = [step(@now, 1, 1, 350), step(DateTime.add(@now, 2 * 3600), 1, 1, 10)]

      a = forecast("A", @now, hourly_a)
      b = forecast("B", @now, steps_b)

      assert {:ok, blended} = Blend.blend([{1, a}, {2, b}], %{1 => 1.0, 2 => 1.0}, @now)
      [_h0, h1 | _] = blended.hours

      # Equal-weight blend of A's 1 deg and B's (correctly) ~0 deg
      # interpolated direction at +1h should land near 0.5, not near 90.5
      # (what a naive scalar lerp of B's 350/10 through 180 produces: the
      # cross-model vector mean of 1 deg and 180 deg).
      #
      # A is deliberately 1 deg, not 0: with A at exactly 0 deg, the buggy
      # scalar-lerp B value (180 deg) is *exactly* antipodal to A, so the
      # cross-model vector sum's magnitude collapses under
      # @zero_magnitude_epsilon and the unrelated zero-magnitude fallback
      # (lowest model id wins ties) silently returns A's 0 deg anyway --
      # masking this bug behind a different one. Nudging A to 1 deg breaks
      # that coincidental cancellation so the assertion actually exercises
      # the per-model interpolation fix (confirmed empirically: at A = 0
      # deg the buggy code returns exactly 0.0, a false GREEN; at A = 1 deg
      # it returns ~90.5, a true RED -- see task-3-blend-report.md).
      assert_direction_close(0.5, h1.dir_deg)
    end
  end

  describe "within-horizon only: short model stops contributing" do
    test "a model past its own horizon drops out of the grid step" do
      # 10/20/40 (not 10/20/30): the 3-way mean (23.333...) and the A+C
      # mean (25.0) are deliberately distinct, so a passing assertion below
      # actually pins WHICH contributors were blended at each step rather
      # than being satisfiable by either combination (10/20/30 would give
      # 20.0 for both, masking a dropped-B or dropped-C bug).
      hourly_a = for h <- 0..48, do: step(DateTime.add(@now, h * 3600), 10, 10, 90)
      short_b = for h <- 0..2, do: step(DateTime.add(@now, h * 3600), 20, 20, 90)
      hourly_c = for h <- 0..48, do: step(DateTime.add(@now, h * 3600), 40, 40, 90)

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
      # full 49-point grid survives: +0h/+1h/+2h blend A+B+C (mean 23.333),
      # the rest blend A+C only (mean 25.0) once B ages out of horizon.
      assert length(abc.hours) == 49
      {within_b_horizon, past_b_horizon} = Enum.split(abc.hours, 3)
      Enum.each(within_b_horizon, &assert_in_delta(&1.wind_kn, 23.333333333333332, 1.0e-9))
      assert Enum.all?(past_b_horizon, &(&1.wind_kn == 25.0))
    end
  end

  describe "fewer than 2 forecasts" do
    test "returns insufficient_models for zero or one constituent" do
      a = forecast("A", @now, [step(@now, 10, 10, 90)])

      assert {:error, :insufficient_models} = Blend.blend([], %{}, @now)
      assert {:error, :insufficient_models} = Blend.blend([{1, a}], %{1 => 1.0}, @now)
    end

    test "no overlapping steps -> insufficient_models" do
      # A only covers +0h..+2h, B only covers +10h..+12h -- two models are
      # passed in (clearing the length(forecasts) < 2 short-circuit), but
      # every point on the common grid has at most 1 in-horizon contributor,
      # so every step is dropped and the overall result is still an error.
      hours_a = for h <- 0..2, do: step(DateTime.add(@now, h * 3600), 10, 10, 90)
      hours_b = for h <- 10..12, do: step(DateTime.add(@now, h * 3600), 20, 20, 90)

      a = forecast("A", @now, hours_a)
      b = forecast("B", @now, hours_b)

      assert {:error, :insufficient_models} =
               Blend.blend([{1, a}, {2, b}], %{1 => 1.0, 2 => 1.0}, @now)
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
      #
      # Pinned to the exact equal-koef blend, not just min/max envelope
      # containment -- an envelope check alone is satisfiable even if a
      # contributor is silently dropped from the mean, so it doesn't
      # actually prove all three constituents were blended.
      #   wind: (7.6 + 4.1 + 6.4) / 3 = 6.033333333333334
      #   dir:  koef-weighted vector mean of 71/72/101 deg = 81.23486272339358
      assert_in_delta first.wind_kn, 6.0333333, 0.001
      assert_direction_close(81.2349, first.dir_deg, 0.01)
    end
  end
end
