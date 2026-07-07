defmodule Stallalert.Windguru.ForecastParser do
  @moduledoc """
  Parses a windguru `iapi.php` forecast payload into a normalized timeline.

  Accepts two shapes, both observed in captured fixtures
  (`docs/windguru-api-notes.md`):

    * the full endpoint response, where the hourly arrays and per-forecast
      metadata are nested one level down under a `"fcst"` key (a sibling
      `"fcst_land"` key may also be present for saved spots — it is ignored);
    * the `fcst` payload itself, unwrapped, with `"initstamp"`/`"hours"`/
      `"WINDSPD"`/etc. at the top level (this is the shape of a body pasted
      directly from a browser session).

  Both shapes normalize to the same output. `hours` offsets are not
  uniform (hourly for roughly the first 78 hours, then 3-hourly out to
  384), so each step's absolute time is computed individually as
  `initstamp + offset * 3600` rather than assumed to be evenly spaced.

  If any of the wind-relevant values (`WINDSPD`, `GUST`, `WINDDIR`) is
  `nil` for a given step, that step is skipped rather than emitted with
  a `nil` field. If the parallel arrays' lengths don't match `hours`,
  parsing fails with `{:error, :unexpected_format}`.
  """

  @type step :: %{time: DateTime.t(), wind_kn: float, gust_kn: float, dir_deg: float}
  @type forecast :: %{model: String.t(), init_time: DateTime.t(), hours: [step]}

  @spec parse(map) :: {:ok, forecast} | {:error, :unexpected_format}
  def parse(%{"fcst" => fcst}) when is_map(fcst), do: parse_fcst(fcst)
  def parse(%{"initstamp" => _, "hours" => _} = payload), do: parse_fcst(payload)
  def parse(_), do: {:error, :unexpected_format}

  defp parse_fcst(%{"initstamp" => init, "hours" => hours} = fcst)
       when is_integer(init) and is_list(hours) do
    speeds = fcst["WINDSPD"]
    gusts = fcst["GUST"]
    dirs = fcst["WINDDIR"]

    with true <- is_list(speeds) and is_list(gusts) and is_list(dirs),
         true <- length(speeds) == length(hours),
         true <- length(gusts) == length(hours),
         true <- length(dirs) == length(hours) do
      steps =
        [hours, speeds, gusts, dirs]
        |> Enum.zip()
        |> Enum.reject(fn {_h, spd, gust, dir} ->
          is_nil(spd) or is_nil(gust) or is_nil(dir)
        end)
        |> Enum.map(fn {h, spd, gust, dir} ->
          %{
            time: DateTime.from_unix!(init + h * 3600),
            wind_kn: spd * 1.0,
            gust_kn: gust * 1.0,
            dir_deg: dir * 1.0
          }
        end)
        |> Enum.sort_by(& &1.time, DateTime)

      {:ok,
       %{
         model: fcst["model_name"] || "unknown",
         init_time: DateTime.from_unix!(init),
         hours: steps
       }}
    else
      _ -> {:error, :unexpected_format}
    end
  end

  defp parse_fcst(_), do: {:error, :unexpected_format}
end
