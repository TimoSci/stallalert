defmodule Stallalert.Windguru.Blend do
  @moduledoc """
  Pure math for blending N normalized Windguru forecasts (the shape produced
  by `Stallalert.Windguru.ForecastParser.parse/1`) into a single "WG blend"
  forecast, independent of how the constituents or their koef weights were
  obtained.

  No adapter calls, no config reads, no `persistent_term` -- everything
  needed comes in as a parameter, so the result is fully determined by its
  inputs and safe to unit test in isolation from `Stallalert.Windguru.
  BlendConfig` (koef weights) and the HTTP/parsing layer (forecasts).

  ## The common grid

  Output steps land on an hourly grid anchored at `now` itself: `now`,
  `now + 1h`, ..., `now + 48h` (49 points, via `DateTime.add/3` in whole
  seconds). This is deliberately *not* truncated to the top of the hour --
  the grid always starts exactly at the `now` passed in.

  ## Per-model interpolation (no extrapolation)

  Each constituent's own hourly/3-hourly steps (Windguru is hourly for
  roughly the first 78h, then 3-hourly -- see `ForecastParser`'s
  moduledoc) are linearly interpolated onto each common grid point
  independently: bracket the two surrounding raw steps, short-circuit on
  an exact time match, and linearly blend `wind_kn`/`gust_kn` by the
  fraction of the interval elapsed.

  `dir_deg` cannot be linearly blended the same way (350 -> 10 must lerp
  through the north seam at 0, not straight through 180), so it is
  interpolated vectorially instead: the bracketing steps' directions are
  each turned into a `{sin, cos}` unit vector, the vectors are lerped
  component-wise by the same fraction, and the result is `atan2`'d back to
  degrees and normalized to `[0, 360)`. If the lerped vector's magnitude is
  negligible (`< 1.0e-9` -- the bracketing steps are opposite directions
  and the fraction lands at the midpoint, 0.5), there is no meaningful
  in-between direction; the fallback is the nearer bracketing step (`frac
  < 0.5` -> before-step, otherwise after-step; exactly `0.5` deterministically
  picks the before-step).

  A model only contributes to a grid step `t` when `t` falls within its
  own published horizon (its first step `<= t <=` its last step) --
  strictly interpolation, never extrapolation. A grid step with fewer
  than 2 contributing models is dropped from the output entirely.

  ## Wind / gust: koef-weighted arithmetic mean

  `wind_kn` and `gust_kn` at a grid step are the koef-weighted arithmetic
  mean of the contributing models' interpolated values at that step,
  weight normalization is implicit (dividing by the sum of the
  *contributing* models' koef, not all constituents' koef -- so a step
  where a heavily-weighted model has dropped out of horizon isn't silently
  under-weighted).

  ## Direction: koef-weighted vector mean

  `dir_deg` cannot be arithmetically averaged (350 and 10 degrees should
  average to 0, not 180). Instead each contributing model's direction is
  turned into a koef-weighted unit vector (`{sin, cos}` in degrees), the
  vectors are summed, and the result direction is
  `atan2(sum_sin, sum_cos)` converted back to degrees and normalized to
  `[0, 360)` (`+360` when the raw `atan2` result is negative).

  If the resultant vector's magnitude is negligible (`< 1.0e-9` --
  opposing directions at equal weight cancel out, e.g. 0 and 180 at koef
  1.0/1.0), there is no meaningful "average direction"; the fallback is
  the direction of the highest-koef contributing model at that step, ties
  broken deterministically by lowest model id.

  ## Output shape

  Same normalized shape as `ForecastParser.parse/1`'s output:
  `model` is `"WG blend (N models)"` where N is the number of input
  forecasts (`length(forecasts)`, not the per-step contributor count,
  which can vary step to step as models fall out of horizon); `init_time`
  is the newest constituent `init_time`; `hours` is the (possibly
  step-dropped) common grid described above.
  """

  @type step :: Stallalert.Windguru.ForecastParser.step()
  @type forecast :: Stallalert.Windguru.ForecastParser.forecast()

  @grid_span_hours 48
  @zero_magnitude_epsilon 1.0e-9
  @deg_to_rad :math.pi() / 180
  @rad_to_deg 180 / :math.pi()

  @spec blend([{integer, forecast}], %{integer => float}, DateTime.t()) ::
          {:ok, forecast} | {:error, :insufficient_models}
  def blend(forecasts, koef, now) when length(forecasts) < 2 do
    _ = {koef, now}
    {:error, :insufficient_models}
  end

  def blend(forecasts, koef, now) do
    hours =
      now
      |> common_grid()
      |> Enum.map(&blend_step(&1, forecasts, koef))
      |> Enum.reject(&is_nil/1)

    case hours do
      [] ->
        {:error, :insufficient_models}

      hours ->
        {:ok,
         %{
           model: "WG blend (#{length(forecasts)} models)",
           init_time: newest_init_time(forecasts),
           hours: hours
         }}
    end
  end

  defp common_grid(now) do
    Enum.map(0..@grid_span_hours, &DateTime.add(now, &1 * 3600, :second))
  end

  defp newest_init_time(forecasts) do
    forecasts
    |> Enum.map(fn {_id, f} -> f.init_time end)
    |> Enum.max(DateTime)
  end

  # A single common-grid point: interpolate every model's own series onto
  # `t` (nil if `t` is outside that model's horizon), then blend whatever
  # is left. Returns nil (dropped step) when fewer than 2 models reach `t`.
  defp blend_step(t, forecasts, koef) do
    contributions =
      forecasts
      |> Enum.map(fn {id, f} -> {id, interpolate_within_horizon(f.hours, t)} end)
      |> Enum.reject(fn {_id, value} -> is_nil(value) end)

    if length(contributions) < 2 do
      nil
    else
      weight_of = fn id -> Map.get(koef, id, 1.0) end
      total_weight = contributions |> Enum.map(fn {id, _v} -> weight_of.(id) end) |> Enum.sum()

      %{
        time: t,
        wind_kn: weighted_mean(contributions, weight_of, total_weight, & &1.wind_kn),
        gust_kn: weighted_mean(contributions, weight_of, total_weight, & &1.gust_kn),
        dir_deg: vector_mean_direction(contributions, weight_of)
      }
    end
  end

  defp weighted_mean(contributions, weight_of, total_weight, field) do
    contributions
    |> Enum.reduce(0.0, fn {id, value}, acc -> acc + weight_of.(id) * field.(value) end)
    |> Kernel./(total_weight)
  end

  defp vector_mean_direction(contributions, weight_of) do
    {sum_sin, sum_cos} =
      Enum.reduce(contributions, {0.0, 0.0}, fn {id, value}, {sum_sin, sum_cos} ->
        weight = weight_of.(id)
        radians = value.dir_deg * @deg_to_rad
        {sum_sin + weight * :math.sin(radians), sum_cos + weight * :math.cos(radians)}
      end)

    magnitude = :math.sqrt(sum_sin * sum_sin + sum_cos * sum_cos)

    if magnitude < @zero_magnitude_epsilon do
      fallback_direction(contributions, weight_of)
    else
      degrees = :math.atan2(sum_sin, sum_cos) * @rad_to_deg
      if degrees < 0, do: degrees + 360, else: degrees
    end
  end

  # Highest koef wins; ties broken by lowest model id, so the fallback is
  # deterministic regardless of input ordering.
  defp fallback_direction(contributions, weight_of) do
    {_id, value} = Enum.min_by(contributions, fn {id, _v} -> {-weight_of.(id), id} end)
    value.dir_deg
  end

  # Mirrors ForecastEngine.interpolate on the watch: bracket the two raw
  # steps surrounding `t`, short-circuit on an exact time match, refuse to
  # extrapolate past either end of the model's own series.
  defp interpolate_within_horizon([], _t), do: nil

  defp interpolate_within_horizon(steps, t) do
    first = List.first(steps)
    last = List.last(steps)

    cond do
      DateTime.compare(t, first.time) == :lt -> nil
      DateTime.compare(t, last.time) == :gt -> nil
      true -> interpolate(steps, t)
    end
  end

  defp interpolate(steps, t) do
    case Enum.find(steps, &(DateTime.compare(&1.time, t) == :eq)) do
      nil -> interpolate_between(steps, t)
      exact -> exact
    end
  end

  defp interpolate_between(steps, t) do
    before = steps |> Enum.filter(&(DateTime.compare(&1.time, t) == :lt)) |> List.last()
    after_ = Enum.find(steps, &(DateTime.compare(&1.time, t) == :gt))

    span = DateTime.diff(after_.time, before.time, :second)
    fraction = DateTime.diff(t, before.time, :second) / span

    %{
      time: t,
      wind_kn: lerp(before.wind_kn, after_.wind_kn, fraction),
      gust_kn: lerp(before.gust_kn, after_.gust_kn, fraction),
      dir_deg: lerp_direction(before.dir_deg, after_.dir_deg, fraction)
    }
  end

  defp lerp(a, b, fraction), do: a + (b - a) * fraction

  # Interpolates a single model's own direction between its two bracketing
  # raw steps vectorially -- lerp the {sin, cos} unit-vector components
  # rather than the raw degrees -- so a step pair like 350 -> 10 blends
  # through the north seam (0) instead of straight through 180. See the
  # "Per-model interpolation" section of the moduledoc.
  defp lerp_direction(before_deg, after_deg, fraction) do
    sin = lerp(:math.sin(before_deg * @deg_to_rad), :math.sin(after_deg * @deg_to_rad), fraction)
    cos = lerp(:math.cos(before_deg * @deg_to_rad), :math.cos(after_deg * @deg_to_rad), fraction)

    if :math.sqrt(sin * sin + cos * cos) < @zero_magnitude_epsilon do
      # Opposite directions at the midpoint (frac 0.5): no meaningful lerped
      # direction. Fall back to the nearer bracketing step; exactly 0.5 is
      # deterministic (before-step wins).
      if fraction < 0.5, do: before_deg, else: after_deg
    else
      degrees = :math.atan2(sin, cos) * @rad_to_deg
      if degrees < 0, do: degrees + 360, else: degrees
    end
  end
end
