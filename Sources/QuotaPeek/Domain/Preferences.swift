import Foundation

struct AppPreferences: Codable, Equatable, Sendable {
    var accounts: [ProviderAccount] = []

    var codexExecutable = ""
    var claudeExecutable = ""
    var kimiExecutable = ""

    var refreshIntervalMinutes = 5
    var notificationThreshold = 20
    var notificationsEnabled = true
    var floatingPanelEnabled = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case accounts
        case codexExecutable
        case claudeExecutable
        case kimiExecutable
        case refreshIntervalMinutes
        case notificationThreshold
        case notificationsEnabled
        case floatingPanelEnabled

        // 仅用于解码旧版偏好；新结构不再编码这些字段。
        case codexEnabled
        case claudeEnabled
        case kimiEnabled
        case glmEnabled
        case grokEnabled
        case glmBaseURL
    }

    /// 容错解码：新版字段缺失就回退默认值。
    /// `accounts` 缺失时说明是旧版单账号配置，用局部解出的旧字段合成"默认"账号，
    /// 账号 id 固定用 `ProviderAccount.legacyDefaultID(for:)`，保证幂等、不用重新登录。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppPreferences()

        let legacyCodexEnabled = try c.decodeIfPresent(Bool.self, forKey: .codexEnabled) ?? true
        let legacyClaudeEnabled = try c.decodeIfPresent(Bool.self, forKey: .claudeEnabled) ?? true
        let legacyKimiEnabled = try c.decodeIfPresent(Bool.self, forKey: .kimiEnabled) ?? true
        let legacyGLMEnabled = try c.decodeIfPresent(Bool.self, forKey: .glmEnabled) ?? true
        let legacyGrokEnabled = try c.decodeIfPresent(Bool.self, forKey: .grokEnabled) ?? true
        let legacyGLMBaseURL = try c.decodeIfPresent(String.self, forKey: .glmBaseURL) ?? "https://open.bigmodel.cn"
        codexExecutable = try c.decodeIfPresent(String.self, forKey: .codexExecutable) ?? d.codexExecutable
        claudeExecutable = try c.decodeIfPresent(String.self, forKey: .claudeExecutable) ?? d.claudeExecutable
        kimiExecutable = try c.decodeIfPresent(String.self, forKey: .kimiExecutable) ?? d.kimiExecutable
        refreshIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? d.refreshIntervalMinutes
        notificationThreshold = try c.decodeIfPresent(Int.self, forKey: .notificationThreshold) ?? d.notificationThreshold
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        floatingPanelEnabled = try c.decodeIfPresent(Bool.self, forKey: .floatingPanelEnabled) ?? d.floatingPanelEnabled

        if let accounts = try c.decodeIfPresent([ProviderAccount].self, forKey: .accounts) {
            self.accounts = accounts
        } else {
            self.accounts = Self.migrateLegacyAccounts(
                codexEnabled: legacyCodexEnabled,
                claudeEnabled: legacyClaudeEnabled,
                kimiEnabled: legacyKimiEnabled,
                glmEnabled: legacyGLMEnabled,
                grokEnabled: legacyGrokEnabled,
                glmBaseURL: legacyGLMBaseURL
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accounts, forKey: .accounts)
        try c.encode(codexExecutable, forKey: .codexExecutable)
        try c.encode(claudeExecutable, forKey: .claudeExecutable)
        try c.encode(kimiExecutable, forKey: .kimiExecutable)
        try c.encode(refreshIntervalMinutes, forKey: .refreshIntervalMinutes)
        try c.encode(notificationThreshold, forKey: .notificationThreshold)
        try c.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try c.encode(floatingPanelEnabled, forKey: .floatingPanelEnabled)
    }

    /// 迁移不看"这个字段是不是 true"——不管开没开，只要旧配置里出现过这个 provider
    /// 就生成一条账号，`enabled` 照抄旧开关状态。这样被关掉的 provider 迁移后还是
    /// 一条禁用账号，用户在新设置页翻一下开关就能用，不需要重新走登录流程。
    private static func migrateLegacyAccounts(
        codexEnabled: Bool, claudeEnabled: Bool, kimiEnabled: Bool,
        glmEnabled: Bool, grokEnabled: Bool, glmBaseURL: String
    ) -> [ProviderAccount] {
        [
            ProviderAccount(id: ProviderAccount.legacyDefaultID(for: .codex), provider: .codex, label: "默认", credential: .cliHome(path: ""), enabled: codexEnabled),
            ProviderAccount(id: ProviderAccount.legacyDefaultID(for: .claude), provider: .claude, label: "默认", credential: .cliHome(path: ""), enabled: claudeEnabled),
            ProviderAccount(id: ProviderAccount.legacyDefaultID(for: .kimi), provider: .kimi, label: "默认", credential: .kimi(cliHomePath: ""), enabled: kimiEnabled),
            ProviderAccount(id: ProviderAccount.legacyDefaultID(for: .glm), provider: .glm, label: "默认", credential: .apiKey(baseURL: glmBaseURL), enabled: glmEnabled),
            ProviderAccount(id: ProviderAccount.legacyDefaultID(for: .grok), provider: .grok, label: "默认", credential: .cookie, enabled: grokEnabled)
        ]
    }

    func isEnabled(_ provider: ProviderID) -> Bool {
        accounts.contains { $0.provider == provider && $0.enabled }
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
