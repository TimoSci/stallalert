import XCTest
@testable import StallAlertKit

final class MicroForecastParserTests: XCTestCase {
    private var fixtureHTML: String {
        let url = Bundle.module.url(forResource: "Fixtures/windguru/micro_forecast", withExtension: "txt")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    func testParsesRealFixture() throws {
        let f = try XCTUnwrap(MicroForecastParser.parse(fixtureHTML))
        XCTAssertEqual(f.model, "gfs-micro")
        XCTAssertEqual(f.initTime, ISO8601DateFormatter().date(from: "2026-07-06T18:00:00Z"))
        XCTAssertEqual(f.hours.count, 179)

        XCTAssertEqual(f.hours[0].windKn, 2)
        XCTAssertEqual(f.hours[0].gustKn, 4)
        XCTAssertEqual(f.hours[0].dirDeg, 122)
        XCTAssertEqual(f.hours[0].time, ISO8601DateFormatter().date(from: "2026-07-06T18:00:00Z"))

        // Fixture spans Jul 6 -> Jul 22 (no month rollover in this real capture); the
        // last row is "Wed 22. 12h  9  9  NNE  14 ..." per the raw file.
        let last = try XCTUnwrap(f.hours.last)
        XCTAssertEqual(last.time, ISO8601DateFormatter().date(from: "2026-07-22T12:00:00Z"))
        XCTAssertEqual(last.windKn, 9)
        XCTAssertEqual(last.gustKn, 9)
        XCTAssertEqual(last.dirDeg, 14)

        XCTAssertEqual(f.hours, f.hours.sorted { $0.time < $1.time })
    }

    func testRejectsGarbageAndTooFewSteps() {
        XCTAssertNil(MicroForecastParser.parse("<html>nope</html>"))

        let tooFew = """
        <pre>
        GFS 13 km (init: 2026-07-06 18 UTC)

          Mon 6. 18h       2       4     ESE     122      28    1018       -       -       -       -       -      55
          Mon 6. 19h       3       2     ENE      67      28    1018       0       0       0       -       0      58
        </pre>
        """
        XCTAssertNil(MicroForecastParser.parse(tooFew))
    }

    func testMonthRollover() throws {
        let html = """
        <pre>
        GFS 13 km (init: 2026-12-31 22 UTC)

          Wed 31. 22h      5       6       N      10      20    1000       0       0       0       -       0      50
          Wed 31. 23h      5       6       N      10      20    1000       0       0       0       -       0      50
          Thu 1. 00h       5       6       N      10      20    1000       0       0       0       -       0      50
          Thu 1. 01h       5       6       N      10      20    1000       0       0       0       -       0      50
        </pre>
        """
        let f = try XCTUnwrap(MicroForecastParser.parse(html))
        XCTAssertEqual(f.initTime, ISO8601DateFormatter().date(from: "2026-12-31T22:00:00Z"))
        XCTAssertEqual(f.hours.count, 4)
        XCTAssertEqual(f.hours[0].time, ISO8601DateFormatter().date(from: "2026-12-31T22:00:00Z"))
        XCTAssertEqual(f.hours[1].time, ISO8601DateFormatter().date(from: "2026-12-31T23:00:00Z"))
        // day goes backwards (31 -> 1): month rolls Dec -> Jan, year rolls 2026 -> 2027
        XCTAssertEqual(f.hours[2].time, ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
        XCTAssertEqual(f.hours[3].time, ISO8601DateFormatter().date(from: "2027-01-01T01:00:00Z"))
    }
}
