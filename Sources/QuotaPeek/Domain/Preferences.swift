import Foundation

struct AppPreferences: Codable, Equatable, Sendable {
    var codexEnabled = true
    var claudeEnabled = true
    var kimiEnabled = true
    var glmEnabled = true
    var grokEnabled = true
    var deepSeekEnabled = true

    var codexExecutable = ""
    var claudeExecutable = ""
    var kimiExecutable = ""
    var glmBaseURL = "https://open.bigmodel.cn"

    var refreshIntervalMinutes = 5
    var notificationThreshold = 20
    var notificationsEnabled = true
    var floatingPanelEnabled = true
    var launchAtLoginEnabled = true

    init() {}

    /// 容错解码：任何字段缺失都回退默认值，保证新增字段时旧偏好数据不整体失效。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppPreferences()
        codexEnabled = try c.decodeIfPresent(Bool.self, forKey: .codexEnabled) ?? d.codexEnabled
        claudeEnabled = try c.decodeIfPresent(Bool.self, forKey: .claudeEnabled) ?? d.claudeEnabled
        kimiEnabled = try c.decodeIfPresent(Bool.self, forKey: .kimiEnabled) ?? d.kimiEnabled
        glmEnabled = try c.decodeIfPresent(Bool.self, forKey: .glmEnabled) ?? d.glmEnabled
        grokEnabled = try c.decodeIfPresent(Bool.self, forKey: .grokEnabled) ?? d.grokEnabled
        deepSeekEnabled = try c.decodeIfPresent(Bool.self, forKey: .deepSeekEnabled) ?? d.deepSeekEnabled
        codexExecutable = try c.decodeIfPresent(String.self, forKey: .codexExecutable) ?? d.codexExecutable
        claudeExecutable = try c.decodeIfPresent(String.self, forKey: .claudeExecutable) ?? d.claudeExecutable
        kimiExecutable = try c.decodeIfPresent(String.self, forKey: .kimiExecutable) ?? d.kimiExecutable
        glmBaseURL = try c.decodeIfPresent(String.self, forKey: .glmBaseURL) ?? d.glmBaseURL
        refreshIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? d.refreshIntervalMinutes
        notificationThreshold = try c.decodeIfPresent(Int.self, forKey: .notificationThreshold) ?? d.notificationThreshold
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        floatingPanelEnabled = try c.decodeIfPresent(Bool.self, forKey: .floatingPanelEnabled) ?? d.floatingPanelEnabled
        launchAtLoginEnabled = try c.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? d.launchAtLoginEnabled
    }

    func isEnabled(_ provider: ProviderID) -> Bool {
        switch provider {
        case .codex: codexEnabled
        case .claude: claudeEnabled
        case .kimi: kimiEnabled
        case .glm: glmEnabled
        case .grok: grokEnabled
        case .deepseek: deepSeekEnabled
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
