import XCTest
@testable import StallAlertKit

final class SettingsTests: XCTestCase {
    func testDefaults() {
        let s = Settings.load(defaults: UserDefaults(suiteName: #function)!, secrets: InMemoryStore())
        XCTAssertEqual(s.thresholdKn, 12)
        XCTAssertNil(s.serviceURL)
    }

    func testRoundTrip() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secrets = InMemoryStore()
        var s = Settings.load(defaults: defaults, secrets: secrets)
        s.thresholdKn = 14
        s.serviceURL = URL(string: "https://stallalert.example.com")
        s.save(defaults: defaults, secrets: secrets)
        secrets.set(Settings.serviceTokenKey, "tok123")

        let reloaded = Settings.load(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reloaded.thresholdKn, 14)
        XCTAssertEqual(reloaded.serviceURL?.host, "stallalert.example.com")
        XCTAssertEqual(secrets.get(Settings.serviceTokenKey), "tok123")
    }
}
