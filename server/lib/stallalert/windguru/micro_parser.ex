defmodule Stallalert.Windguru.MicroParser do
  @moduledoc """
  Parses the `micro.windguru.cz` fallback response into the same normalized
  timeline shape produced by `Stallalert.Windguru.ForecastParser`.

  Unlike `iapi.php`, the micro API is a plain HTML page whose body is a
  `<pre>`-formatted text table (see `docs/windguru-api-notes.md`, "Micro API
  fallback"). Only `m=gfs` returns a real forecast table (`m=wg` — a guessed
  WG-blend model id — returns a header with no rows; omitting `m` defaults
  to `gfs`), so the adapter always requests `m=gfs` and this module
  normalizes the result to `model: "gfs-micro"`.

  Table layout (one row per timestep, hourly out to ~24h then 3-hourly):

      Date          WSPD  GUST  WDIRN  WDEG  TMP  SLP  HCLD  MCLD  LCLD  APCP  APCP1  RH
      (UTC+0)      knots knots  dir.   deg.   C   hPa   %     %     %  mm/3h  mm/1h   %
      Mon 6. 18h      2    4    ESE    122   28  1018    -     -     -    -     -    55

  The fixture carries both a cardinal direction (`WDIRN`) and a numeric
  degree column (`WDEG`); `WDEG` is used directly as `dir_deg` since it's
  already the precise value the normalized shape wants (no 22.5°-step
  cardinal-to-degree conversion needed).

  The `Date` column has no year and, per row, no month — only a day-of-month
  and an hour (e.g. `6. 18h`). The year/month are read once from the page's
  `(init: YYYY-MM-DD HH UTC)` line and then rolled forward a month (and, at
  a December boundary, a year) whenever a row's day-of-month is smaller than
  the previous row's, since rows are always emitted in chronological order.

  The header states `(UTC+0)`, but the capture notes flag this as stated,
  not independently verified against a second known-timezone location (no
  `tz` param was sent). Times are parsed as UTC per the header text; this is
  an assumption, not a confirmed fact — revisit if forecast/actuals disagree
  once the JSON (`iapi.php`) and micro paths are compared in production.

  Parsing fails with `{:error, :unexpected_format}` if the `<pre>` block or
  the init line can't be found, or if fewer than 3 timesteps parse.
  """

  @type step :: %{time: DateTime.t(), wind_kn: float, gust_kn: float, dir_deg: float}
  @type forecast :: %{model: String.t(), init_time: DateTime.t(), hours: [step]}

  @min_steps 3

  @pre_regex ~r/<pre>(.*?)<\/pre>/is
  @init_regex ~r/\(init:\s*(\d{4})-(\d{2})-(\d{2})\s+(\d{1,2})\s+UTC\)/

  @row_regex ~r/^\s*[A-Za-z]{3}\s+(\d{1,2})\.\s+(\d{1,2})h\s+(-?\d+)\s+(-?\d+)\s+[A-Za-z]+\s+(-?\d+)\s+/

  @spec parse(String.t()) :: {:ok, forecast} | {:error, :unexpected_format}
  def parse(text) when is_binary(text) do
    with [_, pre_body] <- Regex.run(@pre_regex, text),
         [_, y, mo, d, h] <- Regex.run(@init_regex, pre_body) do
      init_year = String.to_integer(y)
      init_month = String.to_integer(mo)
      init_day = String.to_integer(d)
      init_hour = String.to_integer(h)

      steps = parse_rows(pre_body, init_year, init_month)

      if length(steps) >= @min_steps do
        {:ok,
         %{
           model: "gfs-micro",
           init_time: build_datetime(init_year, init_month, init_day, init_hour),
           hours: steps
         }}
      else
        {:error, :unexpected_format}
      end
    else
      _ -> {:error, :unexpected_format}
    end
  end

  def parse(_), do: {:error, :unexpected_format}

  defp parse_rows(pre_body, init_year, init_month) do
    pre_body
    |> String.split("\n")
    |> Enum.reduce({init_year, init_month, nil, []}, &parse_row/2)
    |> elem(3)
    |> Enum.reverse()
  end

  defp parse_row(line, {year, month, last_day, acc}) do
    case Regex.run(@row_regex, line) do
      [_, day_str, hour_str, wspd_str, gust_str, wdeg_str] ->
        day = String.to_integer(day_str)
        hour = String.to_integer(hour_str)
        {year, month} = roll_month(year, month, last_day, day)

        step = %{
          time: build_datetime(year, month, day, hour),
          wind_kn: String.to_integer(wspd_str) * 1.0,
          gust_kn: String.to_integer(gust_str) * 1.0,
          dir_deg: String.to_integer(wdeg_str) * 1.0
        }

        {year, month, day, [step | acc]}

      nil ->
        {year, month, last_day, acc}
    end
  end

  # Rows carry only a day-of-month, no year/month — bump the month (and,
  # across December, the year) whenever the day number goes backwards,
  # since rows are always emitted in chronological order.
  defp roll_month(year, month, last_day, day) when is_integer(last_day) and day < last_day do
    if month == 12 do
      {year + 1, 1}
    else
      {year, month + 1}
    end
  end

  defp roll_month(year, month, _last_day, _day), do: {year, month}

  defp build_datetime(year, month, day, hour) do
    Date.new!(year, month, day)
    |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
  end
end
