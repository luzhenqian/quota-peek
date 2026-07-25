import Foundation

struct AppPreferences: Codable, Equatable, Sendable {
    var accounts: [ProviderAccount] = []

    var codexEnabled = true
    var claudeEnabled = true
    var kimiEnabled = true
    var glmEnabled = true
    var grokEnabled = true

    var codexExecutable = ""
    var claudeExecutable = ""
    var kimiExecutable = ""
    var glmBaseURL = "https://open.bigmodel.cn"

    var refreshIntervalMinutes = 5
    var notificationThreshold = 20
    var notificationsEnabled = true
    var floatingPanelEnabled = true

    init() {}

    /// 容错解码：新版字段缺失就回退默认值。`codexEnabled` 等 5 个布尔 + `glmBaseURL`
    /// 本任务原样保留（下面几行正常 decodeIfPresent），Task 12 才会删掉它们——
    /// `SettingsView`/`ProviderFactory`/`AppModel` 到那之前都还在读，删早了编译不过。
    /// `accounts` 缺失时说明是旧版单账号配置，用上面刚解出来的旧字段合成"默认"账号，
    /// 账号 id 固定用 `ProviderAccount.legacyDefaultID(for:)`，保证幂等、不用重新登录。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppPreferences()

        codexEnabled = try c.decodeIfPresent(Bool.self, forKey: .codexEnabled) ?? d.codexEnabled
        claudeEnabled = try c.decodeIfPresent(Bool.self, forKey: .claudeEnabled) ?? d.claudeEnabled
        kimiEnabled = try c.decodeIfPresent(Bool.self, forKey: .kimiEnabled) ?? d.kimiEnabled
        glmEnabled = try c.decodeIfPresent(Bool.self, forKey: .glmEnabled) ?? d.glmEnabled
        grokEnabled = try c.decodeIfPresent(Bool.self, forKey: .grokEnabled) ?? d.grokEnabled
        codexExecutable = try c.decodeIfPresent(String.self, forKey: .codexExecutable) ?? d.codexExecutable
        claudeExecutable = try c.decodeIfPresent(String.self, forKey: .claudeExecutable) ?? d.claudeExecutable
        kimiExecutable = try c.decodeIfPresent(String.self, forKey: .kimiExecutable) ?? d.kimiExecutable
        glmBaseURL = try c.decodeIfPresent(String.self, forKey: .glmBaseURL) ?? d.glmBaseURL
        refreshIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? d.refreshIntervalMinutes
        notificationThreshold = try c.decodeIfPresent(Int.self, forKey: .notificationThreshold) ?? d.notificationThreshold
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        floatingPanelEnabled = try c.decodeIfPresent(Bool.self, forKey: .floatingPanelEnabled) ?? d.floatingPanelEnabled

        if let accounts = try c.decodeIfPresent([ProviderAccount].self, forKey: .accounts) {
            self.accounts = accounts
        } else {
            self.accounts = Self.migrateLegacyAccounts(
                codexEnabled: codexEnabled, claudeEnabled: claudeEnabled, kimiEnabled: kimiEnabled,
                glmEnabled: glmEnabled, grokEnabled: grokEnabled, glmBaseURL: glmBaseURL
            )
        }
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
