import XCTest
@testable import QuotaPeek

final class PreferencesMigrationTests: XCTestCase {
    func testLegacyShapeMigratesToAccounts() throws {
        let legacyJSON = """
        {
          "codexEnabled": true, "claudeEnabled": true, "kimiEnabled": false,
          "glmEnabled": true, "grokEnabled": false,
          "codexExecutable": "/opt/homebrew/bin/codex",
          "claudeExecutable": "", "kimiExecutable": "",
          "glmBaseURL": "https://api.z.ai",
          "refreshIntervalMinutes": 5, "notificationThreshold": 20,
          "notificationsEnabled": true, "floatingPanelEnabled": true
        }
        """
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(prefs.accounts.count, 5, "5 个 provider 在旧配置里都出现过（哪怕是关着的），迁移要保留这个开关状态，不能凭空丢账号")

        let codex = try XCTUnwrap(prefs.accounts.first { $0.provider == .codex })
        XCTAssertEqual(codex.id, ProviderAccount.legacyDefaultID(for: .codex))
        XCTAssertEqual(codex.label, "默认")
        XCTAssertTrue(codex.enabled)
        XCTAssertEqual(codex.credential, .cliHome(path: ""))

        let glm = try XCTUnwrap(prefs.accounts.first { $0.provider == .glm })
        XCTAssertEqual(glm.credential, .apiKey(baseURL: "https://api.z.ai"))

        let kimi = try XCTUnwrap(prefs.accounts.first { $0.provider == .kimi })
        XCTAssertFalse(kimi.enabled, "kimiEnabled 是 false，迁移后账号要保留禁用状态——用户以后在设置里翻一下开关就能用，不用重新登录")

        let grok = try XCTUnwrap(prefs.accounts.first { $0.provider == .grok })
        XCTAssertFalse(grok.enabled)

        XCTAssertEqual(prefs.codexExecutable, "/opt/homebrew/bin/codex", "可执行文件路径这类全局字段照常解码，不参与迁移")
    }

    func testNewShapeWithAccountsSkipsMigration() throws {
        let account = ProviderAccount(
            id: UUID(), provider: .claude, label: "工作",
            credential: .cliHome(path: "/tmp/x"), enabled: true
        )
        var prefs = AppPreferences()
        prefs.accounts = [account]
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        XCTAssertEqual(decoded.accounts, [account], "已经是新版结构时应原样解码，不重新触发迁移生成默认账号")
    }

    func testAbsentLegacyFieldsFallBackToDefaultsAndStillMigrate() throws {
        // init(from:) 只有在真的存在已保存数据时才会被调用——全新安装走
        // PreferencesStore.load() 的 guard 分支，根本不会触发解码。这里测的是
        // "字段确实缺失时怎么办"，不是"全新安装"（那个场景不会调用这个 initializer）。
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(prefs.accounts.count, 5, "所有布尔字段都缺失时回退默认值 true，5 个 provider 都生成默认启用的账号")
        XCTAssertTrue(prefs.accounts.allSatisfy(\.enabled))
    }
}
