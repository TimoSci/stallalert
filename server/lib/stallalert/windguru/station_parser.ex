defmodule Stallalert.Windguru.StationParser do
  @moduledoc """
  Parses windguru `iapi.php` live-station payloads
  (`docs/windguru-api-notes.md`, Endpoints 3 and 4).

  ## `parse_reading/1` — `q=station_data`

  Contrary to a flat single-reading shape, this endpoint returns a
  TIME-WINDOWED series: `unixtime`, `wind_avg`, `wind_max`, `wind_direction`
  (and others, ignored here) are parallel arrays, one element per bucketed
  sample in the requested `from`..`to` window. `parse_reading/1` normalizes
  this down to a single reading: the sample with the greatest `unixtime`
  (the latest one), not simply the last array index — the arrays are
  expected in ascending order but this is not assumed.

  `unixtime` (unix seconds, UTC) is authoritative for the timestamp; the
  sibling `datetime` string is in the station's *local* time
  (`datetime == unixtime + tzoffset`) and is display-only, never used here.

  A sample only counts as usable if `unixtime`, `wind_avg`, `wind_max`, and
  `wind_direction` are all present (non-nil) at that index. If the window is
  empty, or every sample is missing a wind value (the station went silent
  for the whole window), there is no usable sample and parsing fails with
  `{:error, :unexpected_format}` — callers should treat that the same as a
  failed fetch. If the parallel arrays' lengths don't match, parsing fails
  with `{:error, :unexpected_format}`.

  ## `parse_station_list/1` — `q=station_list`

  The real response is a bare JSON array of station objects (not wrapped in
  a `"stations"` key as an earlier draft of this parser assumed). Each
  station has `id_station`, `name` (a hardware/model string, often blank),
  `spotname` (a location string), `lat`, `lon`, among other fields not
  needed for normalization (`uid`, `id_type`, `id_spot`, `wg`, `alt`,
  `timezone`, `seconds_alive`, `weather`).

  Normalization prefers `name` when it's a non-empty string, falling back to
  `spotname`; an entry with neither is skipped. An entry missing a usable
  (integer) `id_station` or (numeric) `lat`/`lon` is also skipped, rather
  than failing the whole list — real-world captures are large and
  heterogeneous, and one malformed entry shouldn't sink the rest (mirrors
  `Stallalert.Windguru.ForecastParser`'s skip-vs-error philosophy). Parsing
  only fails wholesale when the input isn't a list at all, or is a
  non-empty list from which nothing could be parsed.

  Liveness/staleness (`seconds_alive`, or a reading's own timestamp) is
  deliberately NOT filtered here — this module is pure shape normalization;
  staleness is a downstream concern.
  """

  @type reading :: %{time: DateTime.t(), wind_kn: float, gust_kn: float, dir_deg: float}
  @type station :: %{id: integer, name: String.t(), lat: float, lon: float}

  @spec parse_reading(map) :: {:ok, reading} | {:error, :unexpected_format}
  def parse_reading(%{
        "unixtime" => uts,
        "wind_avg" => avgs,
        "wind_max" => maxs,
        "wind_direction" => dirs
      })
      when is_list(uts) and is_list(avgs) and is_list(maxs) and is_list(dirs) do
    with true <- length(uts) == length(avgs),
         true <- length(uts) == length(maxs),
         true <- length(uts) == length(dirs) do
      [uts, avgs, maxs, dirs]
      |> Enum.zip()
      |> Enum.filter(fn {t, avg, max, dir} ->
        is_integer(t) and is_number(avg) and is_number(max) and is_number(dir)
      end)
      |> case do
        [] ->
          {:error, :unexpected_format}

        samples ->
          {t, avg, max, dir} = Enum.max_by(samples, fn {t, _avg, _max, _dir} -> t end)

          {:ok,
           %{
             time: DateTime.from_unix!(t),
             wind_kn: avg * 1.0,
             gust_kn: max * 1.0,
             dir_deg: dir * 1.0
           }}
      end
    else
      _ -> {:error, :unexpected_format}
    end
  end

  def parse_reading(_), do: {:error, :unexpected_format}

  @spec parse_station_list(list) :: {:ok, [station]} | {:error, :unexpected_format}
  def parse_station_list(entries) when is_list(entries) do
    parsed = entries |> Enum.map(&normalize_station/1) |> Enum.reject(&is_nil/1)

    if parsed == [] and entries != [] do
      {:error, :unexpected_format}
    else
      {:ok, parsed}
    end
  end

  def parse_station_list(_), do: {:error, :unexpected_format}

  defp normalize_station(%{"id_station" => id, "lat" => lat, "lon" => lon} = entry)
       when is_integer(id) and is_number(lat) and is_number(lon) do
    case station_name(entry) do
      nil -> nil
      name -> %{id: id, name: name, lat: lat * 1.0, lon: lon * 1.0}
    end
  end

  defp normalize_station(_), do: nil

  defp station_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp station_name(%{"spotname" => name}) when is_binary(name) and name != "", do: name
  defp station_name(_), do: nil
end
