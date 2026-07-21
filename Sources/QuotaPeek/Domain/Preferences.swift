import Foundation

struct AppPreferences: Codable, Equatable, Sendable {
    var codexEnabled = true
    var claudeEnabled = true
    var kimiEnabled = true
    var glmEnabled = true

    var codexExecutable = ""
    var claudeExecutable = ""
    var kimiExecutable = ""
    var glmBaseURL = "https://open.bigmodel.cn"

    var refreshIntervalMinutes = 5
    var notificationThreshold = 20
    var notificationsEnabled = true
    var floatingPanelEnabled = true

    func isEnabled(_ provider: ProviderID) -> Bool {
        switch provider {
        case .codex: codexEnabled
        case .claude: claudeEnabled
        case .kimi: kimiEnabled
        case .glm: glmEnabled
        }
    }
}

enum PreferencesStore {
    private static let key = "QuotaPeek.preferences.v1"

    static func load() -> AppPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(AppPreferences.self, from: data) else {
            return AppPreferences()
        }
        return value
    }

    static func save(_ preferences: AppPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
