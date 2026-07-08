import Foundation

/// Parses the `micro.windguru.cz` fallback response into a `Forecast`.
///
/// Unlike the JSON `iapi.php` forecast, the micro API is a plain HTML page
/// whose body is a `<pre>`-formatted text table (see
/// `docs/windguru-api-notes.md`, "Micro API fallback"). Only `m=gfs` returns
/// a real forecast table, so the client always requests `m=gfs` and this
/// parser normalizes the result to `model: "gfs-micro"`.
///
/// Mirrors `Stallalert.Windguru.MicroParser` (server/lib/stallalert/windguru/micro_parser.ex)
/// semantically:
///
///   - The `Date` column has no year and, per row, no month — only a
///     day-of-month and an hour (e.g. `6. 18h`). Year/month are read once
///     from the page's `(init: YYYY-MM-DD HH UTC)` line, then rolled forward
///     a month (and, at a December boundary, a year) whenever a row's
///     day-of-month is smaller than the previous row's, since rows are
///     always emitted in chronological order.
///   - Times are parsed as UTC, per the table's `(UTC+0)` header.
///   - Parsing fails (returns `nil`) if the `<pre>` block or the init line
///     can't be found, or if fewer than 3 timesteps parse.
///
/// Note: the row-matching regex below intentionally mirrors the reference
/// Elixir implementation's pattern (day-of-week exactly 3 letters, integer
/// wind/gust/degree columns, no end-of-line anchor) rather than a stricter
/// end-anchored pattern, because real fixture rows have several more
/// numeric columns (TMP, SLP, cloud cover, precip, RH) after the degrees
/// column — an end anchor placed right after degrees would never match.
public enum MicroForecastParser {
    private static let minSteps = 3

    private static let preRegex = try! NSRegularExpression(
        pattern: "<pre>([\\s\\S]*?)</pre>",
        options: [.caseInsensitive]
    )

    private static let initRegex = try! NSRegularExpression(
        pattern: "\\(init:\\s*(\\d{4})-(\\d{2})-(\\d{2})\\s+(\\d{1,2})\\s+UTC\\)"
    )

    // Day-of-week (3 letters), day-of-month, hour, wind, gust, cardinal
    // direction (ignored), numeric degrees. No trailing anchor: several more
    // columns (temp, pressure, cloud cover, precip, humidity) follow.
    private static let rowRegex = try! NSRegularExpression(
        pattern: "^\\s*[A-Za-z]{3}\\s+(\\d{1,2})\\.\\s+(\\d{1,2})h\\s+(-?\\d+)\\s+(-?\\d+)\\s+[A-Za-z]+\\s+(-?\\d+)\\s+"
    )

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Parses a micro-API HTML page. Returns `nil` unless at least 3
    /// timesteps parse successfully; `model` is always `"gfs-micro"`; all
    /// times are UTC.
    public static func parse(_ html: String) -> Forecast? {
        guard let preBody = extractPreBody(html) else { return nil }
        guard let (year, month, day, hour) = extractInit(preBody) else { return nil }

        var steps: [WindStep] = []
        var currentYear = year
        var currentMonth = month
        var lastDay: Int?

        for line in preBody.components(separatedBy: "\n") {
            guard let row = matchRow(line) else { continue }

            if let previousDay = lastDay, row.day < previousDay {
                if currentMonth == 12 {
                    currentMonth = 1
                    currentYear += 1
                } else {
                    currentMonth += 1
                }
            }

            guard let time = utcDate(year: currentYear, month: currentMonth, day: row.day, hour: row.hour) else {
                continue
            }

            steps.append(WindStep(
                time: time,
                windKn: Double(row.wind),
                gustKn: Double(row.gust),
                dirDeg: Double(row.deg)
            ))
            lastDay = row.day
        }

        guard steps.count >= minSteps else { return nil }
        guard let initTime = utcDate(year: year, month: month, day: day, hour: hour) else { return nil }

        return Forecast(model: "gfs-micro", initTime: initTime, hours: steps)
    }

    private static func extractPreBody(_ html: String) -> String? {
        let ns = html as NSString
        guard let match = preRegex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    private static func extractInit(_ preBody: String) -> (year: Int, month: Int, day: Int, hour: Int)? {
        let ns = preBody as NSString
        guard let match = initRegex.firstMatch(in: preBody, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges == 5,
              let year = Int(ns.substring(with: match.range(at: 1))),
              let month = Int(ns.substring(with: match.range(at: 2))),
              let day = Int(ns.substring(with: match.range(at: 3))),
              let hour = Int(ns.substring(with: match.range(at: 4))) else {
            return nil
        }
        return (year, month, day, hour)
    }

    private struct RowMatch {
        let day: Int
        let hour: Int
        let wind: Int
        let gust: Int
        let deg: Int
    }

    private static func matchRow(_ line: String) -> RowMatch? {
        let ns = line as NSString
        guard let match = rowRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges == 6,
              let day = Int(ns.substring(with: match.range(at: 1))),
              let hour = Int(ns.substring(with: match.range(at: 2))),
              let wind = Int(ns.substring(with: match.range(at: 3))),
              let gust = Int(ns.substring(with: match.range(at: 4))),
              let deg = Int(ns.substring(with: match.range(at: 5))) else {
            return nil
        }
        return RowMatch(day: day, hour: hour, wind: wind, gust: gust, deg: deg)
    }

    private static func utcDate(year: Int, month: Int, day: Int, hour: Int) -> Date? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        return utcCalendar.date(from: comps)
    }
}
