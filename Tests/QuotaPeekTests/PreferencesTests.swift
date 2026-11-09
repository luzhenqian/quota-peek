import XCTest
@testable import QuotaPeek

final class PreferencesTests: XCTestCase {
    func testLaunchAtLoginDefaultsToEnabled() throws {
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))

        XCTAssertTrue(preferences.launchAtLoginEnabled)
    }

    func testLaunchAtLoginPreferenceRoundTrips() throws {
        var preferences = AppPreferences()
        preferences.launchAtLoginEnabled = false

        let encoded = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: encoded)

        XCTAssertFalse(decoded.launchAtLoginEnabled)
    }

    func testDeepSeekDefaultsToEnabledForExistingPreferences() throws {
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))

        XCTAssertTrue(preferences.deepSeekEnabled)
        XCTAssertTrue(preferences.isEnabled(.deepseek))
    }
}
