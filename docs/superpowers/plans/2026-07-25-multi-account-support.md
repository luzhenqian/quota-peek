# 多账号支持 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 QuotaPeek 支持同一个 Provider（Codex/Claude/Kimi/GLM/Grok）挂多个账号，各自独立刷新、独立参与卡片排序与推荐算法，旧版单账号用户升级后无需重新登录任何东西。

**Architecture:** 引入 `ProviderAccount`（provider + UUID + 手动标签 + 凭证）取代"一个 Provider 一份配置"的假设；CLI 类账号靠环境变量重定向登录目录隔离（`CLAUDE_CONFIG_DIR`/`CODEX_HOME`/`KIMI_CODE_HOME`），API Key/Cookie/Kimi 网页会话按账号 UUID 分开存储；`ProviderSnapshot` 从按 `ProviderID` 建索引改成按账号 UUID 建索引。旧配置通过每个 Provider 一个固定 UUID 幂等迁移成"默认账号"。

**Tech Stack:** Swift 6.2 / SwiftUI / AppKit / WebKit（`WKWebsiteDataStore(forIdentifier:)`）/ XCTest / Keychain（Security 框架）。

## Global Constraints

- macOS 14+，Swift 6.2+（`Package.swift` 已声明）。
- 不引入新的第三方依赖；WebKit 已在 `Package.swift` 里 link 过，直接用。
- 默认不写注释；只在"为什么"不直观时写一行中文注释（沿用本仓库现有风格，见已有文件）。
- 每个 `ProviderSnapshot`/`ProviderAccount` 相关的新代码必须是 `Sendable`（协议约束已经贯穿全仓库）。
- 参考设计文档：`docs/superpowers/specs/2026-07-25-multi-account-support-design.md`（已获用户批准）。

---

## 背景速览（写给不熟悉这个仓库的实现者）

QuotaPeek 是个 macOS 菜单栏 App，每 N 分钟并发探测 5 家 AI 订阅（Codex/Claude/Kimi/GLM/Grok）的额度，展示在下拉面板里。现状：`ProviderID`（5 个 case 的 enum）既是"服务商类型"又是"数据身份"——每个 Provider 只能有一份配置、一份凭证、一张卡片。这次要改成"一个 Provider 可以有 N 个账号"，账号成为新的身份单元。

关键现状文件（实现前务必读一遍）：
- `Sources/QuotaPeek/Domain/Models.swift` — `ProviderID` / `QuotaWindow` / `ProviderSnapshot` / `ProviderProbe` 协议。
- `Sources/QuotaPeek/Domain/Preferences.swift` — `AppPreferences`（当前是 5×enabled + 3×executable + glmBaseURL 的扁平结构）。
- `Sources/QuotaPeek/App/AppModel.swift` — `@MainActor` 单例，`refreshAll()` 是核心刷新循环。
- `Sources/QuotaPeek/Providers/*.swift` — 5 个 `ProviderProbe` 实现 + `ProviderFactory`。
- `Sources/QuotaPeek/Infrastructure/{SecretStore,KimiWebSession,ProcessRunner}.swift`。
- `Sources/QuotaPeek/UI/{SettingsView,DashboardViews}.swift`。

运行测试：`swift test`（全部在 `Tests/QuotaPeekTests/`，纯逻辑测试，不需要真实登录任何 CLI）。
本地构建可运行的 `.app`：`scripts/build-app.sh`，产物在 `dist/QuotaPeek.app`。

---

### Task 1: `ProviderAccount` 数据类型

**Files:**
- Create: `Sources/QuotaPeek/Domain/ProviderAccount.swift`
- Test: `Tests/QuotaPeekTests/ProviderAccountTests.swift`

**Interfaces:**
- Produces: `ProviderAccount`（`id: UUID`, `provider: ProviderID`, `label: String`, `credential: AccountCredential`, `enabled: Bool`）、`AccountCredential`（`.cliHome(path:)` / `.kimi(cliHomePath:)` / `.apiKey(baseURL:)` / `.cookie`）、`ProviderAccount.legacyDefaultID(for:) -> UUID`、`ProviderAccount.keychainKey: String?`、`AccountCredential.cliHomeDirectory: String?`。后续所有任务都依赖这几个类型/方法的确切名字。

- [ ] **Step 1: 写新文件**

```swift
import Foundation

struct ProviderAccount: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var provider: ProviderID
    var label: String
    var credential: AccountCredential
    var enabled: Bool = true
}

enum AccountCredential: Codable, Equatable, Sendable {
    case cliHome(path: String)      // Claude / Codex：CLI 配置目录路径，空串 = 用 CLI 自己的默认目录
    case kimi(cliHomePath: String)  // Kimi：同上的 CLI 目录；是否叠加网页登录由 per-account 的
                                     // UserDefaults 标志位判断（见 KimiWebSession），不在这里存
    case apiKey(baseURL: String)    // GLM：密钥本身存 Keychain，这里只留 base URL
    case cookie                     // Grok：密钥本身存 Keychain
}

extension ProviderAccount {
    /// 迁移旧版单账号配置时使用的固定 UUID，每个 Provider 各一个。
    /// 固定值保证 Keychain key、WKWebsiteDataStore identifier 等派生值
    /// 在多次启动 / 重复迁移之间保持稳定、幂等（不会每次启动生成新账号）。
    static func legacyDefaultID(for provider: ProviderID) -> UUID {
        switch provider {
        case .codex:  UUID(uuidString: "6D1A1000-0000-4000-8000-000000000001")!
        case .claude: UUID(uuidString: "6D1A1000-0000-4000-8000-000000000002")!
        case .kimi:   UUID(uuidString: "6D1A1000-0000-4000-8000-000000000003")!
        case .glm:    UUID(uuidString: "6D1A1000-0000-4000-8000-000000000004")!
        case .grok:   UUID(uuidString: "6D1A1000-0000-4000-8000-000000000005")!
        }
    }

    /// Keychain 存取用的账号字符串；只有 GLM/Grok 这类密钥型凭证需要，其余返回 nil。
    var keychainKey: String? {
        switch (provider, credential) {
        case (.glm, .apiKey): "glm-api-key-\(id.uuidString)"
        case (.grok, .cookie): "grok-cookie-\(id.uuidString)"
        default: nil
        }
    }
}

extension AccountCredential {
    /// CLI 类凭证的登录目录路径；非 CLI 凭证返回 nil。用于把同目录的探针分到一组顺序重试。
    var cliHomeDirectory: String? {
        switch self {
        case .cliHome(let path): path
        case .kimi(let path): path
        case .apiKey, .cookie: nil
        }
    }
}
```

- [ ] **Step 2: 写测试**

```swift
import XCTest
@testable import QuotaPeek

final class ProviderAccountTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let account = ProviderAccount(
            id: UUID(), provider: .claude, label: "工作",
            credential: .cliHome(path: "/tmp/foo"), enabled: true
        )
        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(ProviderAccount.self, from: data)
        XCTAssertEqual(decoded, account)
    }

    func testLegacyDefaultIDsAreStableAndDistinct() {
        let ids = ProviderID.allCases.map(ProviderAccount.legacyDefaultID(for:))
        XCTAssertEqual(Set(ids).count, ProviderID.allCases.count, "每个 Provider 的迁移 UUID 必须互不相同")
        XCTAssertEqual(
            ProviderAccount.legacyDefaultID(for: .claude),
            ProviderAccount.legacyDefaultID(for: .claude),
            "同一 Provider 多次调用必须返回同一个 UUID（幂等）"
        )
    }

    func testKeychainKeyOnlyForSecretBasedCredentials() {
        let glm = ProviderAccount(
            id: UUID(), provider: .glm, label: "默认",
            credential: .apiKey(baseURL: "https://open.bigmodel.cn"), enabled: true
        )
        XCTAssertEqual(glm.keychainKey, "glm-api-key-\(glm.id.uuidString)")

        let claude = ProviderAccount(
            id: UUID(), provider: .claude, label: "默认",
            credential: .cliHome(path: ""), enabled: true
        )
        XCTAssertNil(claude.keychainKey)
    }

    func testCLIHomeDirectoryExtraction() {
        XCTAssertEqual(AccountCredential.cliHome(path: "/tmp/a").cliHomeDirectory, "/tmp/a")
        XCTAssertEqual(AccountCredential.kimi(cliHomePath: "/tmp/b").cliHomeDirectory, "/tmp/b")
        XCTAssertNil(AccountCredential.apiKey(baseURL: "x").cliHomeDirectory)
        XCTAssertNil(AccountCredential.cookie.cliHomeDirectory)
    }
}
```

- [ ] **Step 3: 跑测试确认通过**

Run: `swift test --filter ProviderAccountTests`
Expected: 4 个测试全部 PASS。

- [ ] **Step 4: Commit**

```bash
git add Sources/QuotaPeek/Domain/ProviderAccount.swift Tests/QuotaPeekTests/ProviderAccountTests.swift
git commit -m "feat: 新增 ProviderAccount 账号数据模型"
```

---

### Task 2: `ProviderSnapshot` 按账号建身份

**Files:**
- Modify: `Sources/QuotaPeek/Domain/Models.swift:167-215`（`ProviderSnapshot` 结构体）
- Test: `Tests/QuotaPeekTests/ProviderSnapshotIdentityTests.swift`（新建）

**Interfaces:**
- Consumes: 无（不依赖 Task 1）。
- Produces: `ProviderSnapshot.accountID: UUID`（默认 `UUID()`）、`ProviderSnapshot.id` 现在等于 `accountID`、`ProviderSnapshot.failure(accountID:provider:label:message:source:previous:)`（`accountID`/`label` 均带默认值，向后兼容）。后续所有引用 `.failure(...)` 或 `snapshot.id` 的代码都要认这个签名。

**背景**：现在 `var id: ProviderID { provider }`，一个 Provider 只能有一张卡片。要改成按 UUID 建身份。给 `accountID` 一个 `= UUID()` 的属性默认值，是为了让 5 个 Provider 的 parser（`ClaudeUsageParser.parse` 等）**完全不用改动**——它们本来就不知道、也不需要知道"账号"这个概念，账号身份由 `AppModel` 在 fetch 成功之后再盖上去（见 Task 9）。

- [ ] **Step 1: 写测试（先失败）**

创建 `Tests/QuotaPeekTests/ProviderSnapshotIdentityTests.swift`：

```swift
import XCTest
@testable import QuotaPeek

final class ProviderSnapshotIdentityTests: XCTestCase {
    func testSnapshotIDDefaultsToFreshUUIDWhenOmitted() {
        let a = ProviderSnapshot(
            provider: .codex, windows: [], balance: nil, plan: nil,
            account: nil, source: .localRPC, capturedAt: Date(), errorMessage: nil
        )
        let b = ProviderSnapshot(
            provider: .codex, windows: [], balance: nil, plan: nil,
            account: nil, source: .localRPC, capturedAt: Date(), errorMessage: nil
        )
        XCTAssertNotEqual(a.id, b.id, "省略 accountID 时应各自拿到独立随机 UUID")
        XCTAssertEqual(a.id, a.accountID)
    }

    func testFailureCarriesAccountIdentity() {
        let id = UUID()
        let snapshot = ProviderSnapshot.failure(
            accountID: id, provider: .claude, label: "工作",
            message: "需要登录", source: .cli
        )
        XCTAssertEqual(snapshot.accountID, id)
        XCTAssertEqual(snapshot.account, "工作")
        XCTAssertEqual(snapshot.errorMessage, "需要登录")
    }

    func testFailurePreservesPreviousIdentityWhenReusingCache() {
        let id = UUID()
        let previous = ProviderSnapshot(
            accountID: id, provider: .claude, windows: [], balance: nil,
            plan: "MAX", account: "工作", source: .cli, capturedAt: Date(), errorMessage: nil
        )
        let snapshot = ProviderSnapshot.failure(
            provider: .claude, label: "会被忽略", message: "超时", source: .cli, previous: previous
        )
        XCTAssertEqual(snapshot.accountID, id)
        XCTAssertEqual(snapshot.account, "工作", "复用旧快照时应保留原账号标签，不被新传入的 label 覆盖")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ProviderSnapshotIdentityTests`
Expected: FAIL —— `ProviderSnapshot` 目前没有 `accountID` 参数，编译不过。

- [ ] **Step 3: 修改 `Models.swift`**

把第 167-215 行的 `ProviderSnapshot` 替换为：

```swift
struct ProviderSnapshot: Identifiable, Hashable, Codable, Sendable {
    var id: UUID { accountID }
    var accountID: UUID = UUID()
    var provider: ProviderID
    var windows: [QuotaWindow]
    var balance: ProviderBalance?
    var plan: String?
    var account: String?
    var source: SnapshotSource
    var capturedAt: Date
    var errorMessage: String?

    var minimumRemainingPercent: Double? {
        windows.map(\.remainingPercent).min()
    }

    /// 该卡片最应该被关注的窗口：优先级最高的一个（月 > 周 > ...），同优先级保留原始顺序。
    var headlineWindow: QuotaWindow? {
        windows.enumerated()
            .min { lhs, rhs in
                let (lp, rp) = (lhs.element.kind.displayPriority, rhs.element.kind.displayPriority)
                return lp != rp ? lp < rp : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    var isStale: Bool {
        Date().timeIntervalSince(capturedAt) > 30 * 60
    }

    static func failure(
        accountID: UUID = UUID(),
        provider: ProviderID,
        label: String? = nil,
        message: String,
        source: SnapshotSource,
        previous: ProviderSnapshot? = nil
    ) -> ProviderSnapshot {
        var snapshot = previous ?? ProviderSnapshot(
            accountID: accountID,
            provider: provider,
            windows: [],
            balance: nil,
            plan: nil,
            account: label,
            source: source,
            capturedAt: Date(),
            errorMessage: nil
        )
        snapshot.errorMessage = message
        return snapshot
    }
}
```

（只动了这一个结构体，`ProviderID` / `QuotaWindow` / `ProviderBalance` / `SnapshotSource` / `ProbeError` / `ProviderResult` / `ProviderProbe` 协议原样不动。）

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter ProviderSnapshotIdentityTests`
Expected: 3 个测试 PASS。

- [ ] **Step 5: 跑现有解析测试确认零回归**

Run: `swift test --filter ProviderParserTests`
Expected: 全部照旧 PASS（5 家 parser 的 `ProviderSnapshot(...)` 调用点都省略了 `accountID`，靠新默认值编译通过）。

- [ ] **Step 6: Commit**

```bash
git add Sources/QuotaPeek/Domain/Models.swift Tests/QuotaPeekTests/ProviderSnapshotIdentityTests.swift
git commit -m "feat: ProviderSnapshot 按账号 UUID 建立身份"
```

---

### Task 3: 推荐算法挪成独立纯函数模块

**Files:**
- Create: `Sources/QuotaPeek/Domain/Recommendation.swift`
- Test: `Tests/QuotaPeekTests/RecommendationTests.swift`

**Interfaces:**
- Consumes: `ProviderSnapshot.accountID`（Task 2）、`ProviderSnapshot.headlineWindow`（已存在）。
- Produces: `Recommendation.recommendedAccountID(among: [ProviderSnapshot], now: Date = Date()) -> UUID?`、`Recommendation.score(for: ProviderSnapshot, now: Date = Date()) -> Double?`。Task 9 会把 `AppModel` 里同名的私有实现整个删掉，改成调用这两个函数。

**背景**：这套打分逻辑现在是 `AppModel` 里的 `private static func`，只能通过 `@MainActor` 单例间接测。逻辑本身不需要 `AppModel` 的任何状态，纯函数化之后可以直接单测，也是这次"账号化"改造里少数不需要碰 `AppModel`/`AppPreferences` 就能独立完成的部分。**这一步先不动 `AppModel.swift`**——它现在仍是自己的私有实现，Task 9 才会切过来，避免这里节外生枝。

- [ ] **Step 1: 写测试（先失败）**

```swift
import XCTest
@testable import QuotaPeek

final class RecommendationTests: XCTestCase {
    private func snapshot(accountID: UUID, remaining: Double, hoursUntilReset: Double?) -> ProviderSnapshot {
        let resetsAt = hoursUntilReset.map { Date().addingTimeInterval($0 * 3_600) }
        let window = QuotaWindow(kind: .weekly, remainingPercent: remaining, resetsAt: resetsAt, resetDescription: nil)
        return ProviderSnapshot(
            accountID: accountID, provider: .claude, windows: [window],
            balance: nil, plan: nil, account: nil, source: .cli,
            capturedAt: Date(), errorMessage: nil
        )
    }

    func testPrefersSoonExpiringOverDistantEvenWithLessRemaining() {
        let soon = UUID()
        let distant = UUID()
        let snapshots = [
            snapshot(accountID: distant, remaining: 90, hoursUntilReset: 144),
            snapshot(accountID: soon, remaining: 70, hoursUntilReset: 2)
        ]
        XCTAssertEqual(Recommendation.recommendedAccountID(among: snapshots), soon)
    }

    func testIgnoresAccountsWithNothingLeft() {
        let empty = snapshot(accountID: UUID(), remaining: 0, hoursUntilReset: 1)
        XCTAssertNil(Recommendation.recommendedAccountID(among: [empty]))
    }

    func testUnknownResetTimeUsesNeutralWeight() {
        let id = UUID()
        let window = QuotaWindow(kind: .model("Grok 4"), remainingPercent: 40, resetsAt: nil, resetDescription: "24 小时窗口")
        let snap = ProviderSnapshot(
            accountID: id, provider: .grok, windows: [window], balance: nil,
            plan: nil, account: nil, source: .officialAPI, capturedAt: Date(), errorMessage: nil
        )
        XCTAssertEqual(Recommendation.score(for: snap) ?? -1, 20, accuracy: 0.001) // 40 * 0.5
    }

    func testEmptySnapshotListHasNoRecommendation() {
        XCTAssertNil(Recommendation.recommendedAccountID(among: []))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter RecommendationTests`
Expected: FAIL —— `Recommendation` 还不存在，编译不过。

- [ ] **Step 3: 写实现**

```swift
import Foundation

/// 各家额度到期不结转，未用完就浪费。给每个账号的"头号指标"
/// （`ProviderSnapshot.headlineWindow`，月 > 周 > ...）按「剩余量 × 刷新紧迫度」打分，
/// 分最高的账号就是最该优先用的那个。纯函数，脱离 AppModel 单独可测。
enum Recommendation {
    static func recommendedAccountID(among snapshots: [ProviderSnapshot], now: Date = Date()) -> UUID? {
        let scored = snapshots.compactMap { snapshot -> (UUID, Double)? in
            score(for: snapshot, now: now).map { (snapshot.accountID, $0) }
        }
        return scored.max(by: { $0.1 < $1.1 })?.0
    }

    static func score(for snapshot: ProviderSnapshot, now: Date = Date()) -> Double? {
        guard let window = snapshot.headlineWindow, window.remainingPercent > 0 else { return nil }
        guard let resetsAt = window.resetsAt else {
            // 不知道具体刷新时间（如 Grok 的滚动窗口），按中性紧迫度处理，既不抢跑也不被埋没。
            return window.remainingPercent * 0.5
        }
        let hoursUntilReset = max(0, resetsAt.timeIntervalSince(now) / 3_600)
        let urgency = 24 / (24 + hoursUntilReset)
        return window.remainingPercent * urgency
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter RecommendationTests`
Expected: 4 个测试 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/QuotaPeek/Domain/Recommendation.swift Tests/QuotaPeekTests/RecommendationTests.swift
git commit -m "refactor: 推荐算法挪成独立可测的纯函数模块"
```

---

### Task 4: `AppPreferences` 新增账号数组 + 旧配置迁移（附加式，不删旧字段）

**Files:**
- Modify: `Sources/QuotaPeek/Domain/Preferences.swift`（整份重写）
- Test: `Tests/QuotaPeekTests/PreferencesMigrationTests.swift`（新建）

**Interfaces:**
- Consumes: `ProviderAccount` / `AccountCredential` / `ProviderAccount.legacyDefaultID(for:)`（Task 1）。
- Produces: `AppPreferences.accounts: [ProviderAccount]`。

**背景**：这一步**只加不删**——`codexEnabled`/`claudeEnabled`/.../`glmBaseURL` 这些旧字段本任务保留，`codexExecutable`/`claudeExecutable`/`kimiExecutable` 三个 CLI 可执行文件路径本来就是"一个 Provider 一条路径"的全局设置（跟账号无关，多账号也不需要拆分——同一个 CLI 二进制，登陆目录才是账号维度），永久保留，不参与本任务的迁移逻辑。`codexEnabled` 等 5 个布尔 + `glmBaseURL` 会在 Task 12 被删掉，删之前 `SettingsView`/`ProviderFactory`/`AppModel` 都还在读它们，所以现在还不能删——这是刻意的过渡态，保证每个任务边界都能编译通过、跑测试。

- [ ] **Step 1: 写测试（先失败）**

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter PreferencesMigrationTests`
Expected: FAIL —— `AppPreferences` 还没有 `accounts` 字段。

- [ ] **Step 3: 重写 `Preferences.swift`**

```swift
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
```

注意：`codexEnabled` 等 5 个布尔字段现在**同时**驱动 `isEnabled(_:)` 的旧读法（`SettingsView`/`AppModel`/`ProviderFactory` 眼下还在读）——但 `isEnabled(_:)` 本身已经改成看 `accounts`，所以从这个任务起，真正决定探针是否运行的是 `accounts` 数组，那 5 个布尔字段只是"迁移时的历史输入 + 暂时还没改造完的旧 UI 绑定"，纯粹的展示层残留，不再是事实来源。Task 9 会把 `AppModel`/`ProviderFactory` 切到 `accounts`，Task 11 会把 `SettingsView` 换成账号列表 UI 不再绑定这些旧字段，Task 12 才真正删掉它们。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter PreferencesMigrationTests`
Expected: 3 个测试 PASS。

- [ ] **Step 5: 全量跑一遍确认没有破坏别的地方**

Run: `swift build && swift test`
Expected: 编译通过，全部测试 PASS（`SettingsView`/`AppModel`/`ProviderFactory` 目前读的是 `codexEnabled` 等旧字段，本任务原样保留没有删除或改名，不受影响）。

- [ ] **Step 6: Commit**

```bash
git add Sources/QuotaPeek/Domain/Preferences.swift Tests/QuotaPeekTests/PreferencesMigrationTests.swift
git commit -m "feat: AppPreferences 新增账号数组，旧版配置幂等迁移"
```

---

### Task 5: `KimiWebSession` 参数化（去掉硬编码单例，保留 `.shared` 兼容旧调用）

**Files:**
- Modify: `Sources/QuotaPeek/Infrastructure/KimiWebSession.swift`（整份）
- Modify: `Sources/QuotaPeek/App/AppModel.swift:180-182`（`kimiWebIsLoggedIn()`，一行修）
- Modify: `Sources/QuotaPeek/Providers/ProviderFactory.swift:11-15`（`KimiWebSession.isLoggedIn` 引用，一行修）

**Interfaces:**
- Consumes: 无新依赖。
- Produces: `KimiWebSession.init(dataStore: WKWebsiteDataStore, loginFlagKey: String)`、实例属性 `isLoggedIn: Bool`（原来是 `nonisolated static var`，现在是普通 `@MainActor` 实例属性）、`KimiWebSession.legacyLoggedInDefaultsKey: String`（原来的固定 UserDefaults key，改名保留给 `.shared` 用）。`KimiWebSession.shared` 依然存在，指向绑定 `.default()` data store 的实例，供 Task 9 之前的所有旧调用方保持编译通过。Task 10 会新增按账号取 `KimiWebSession` 实例的逻辑，届时 `.shared` 就不再被引用，可以留着当兼容出口，不强制删除。

**这一步没有自动化测试**——`KimiWebSession` 整个包在 `WKWebView` 上，本仓库现有做法（见 `docs/superpowers/specs/2026-07-21-kimi-web-session-design.md` 的"测试"一节）就是不测这层，靠真机手工验证登录/刷新。本任务只用编译通过 + 手工冒烟来验收。

- [ ] **Step 1: 重写 `KimiWebSession.swift`**

把文件顶部到 `presentLogin()`/`logout()` 之间的部分改成：

```swift
import AppKit
import WebKit

@MainActor
final class KimiWebSession: NSObject {
    /// 迁移期兼容：多账号改造完成前，唯一的 Kimi 网页会话，绑定系统默认 data store。
    /// Task 10 起 AppModel 会按账号构造独立实例，不再依赖这个单例；保留它只是为了
    /// 让 Task 5～9 之间还没迁移完的旧调用点继续编译通过。
    static let shared = KimiWebSession(dataStore: .default(), loginFlagKey: legacyLoggedInDefaultsKey)

    nonisolated static let legacyLoggedInDefaultsKey = "QuotaPeek.kimiWebLoggedIn"
    private let membershipHome = URL(string: "https://www.kimi.com/membership/subscription")!
    private let dataStore: WKWebsiteDataStore
    private let loginFlagKey: String

    var isLoggedIn: Bool {
        get { UserDefaults.standard.bool(forKey: loginFlagKey) }
        set { UserDefaults.standard.set(newValue, forKey: loginFlagKey) }
    }

    // 常驻 WebView：持久 data store，让 cookie + localStorage 落地磁盘，
    // token 刷新交给 Kimi 网页 JS。
    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        return wv
    }()

    init(dataStore: WKWebsiteDataStore, loginFlagKey: String) {
        self.dataStore = dataStore
        self.loginFlagKey = loginFlagKey
        super.init()
    }
```

`ensureLoaded()` / `loadChain` / `load(_:in:)` / `performLoad(_:in:)` / `retainedDelegate` / `readAccessToken(in:)` / `fetchMembership()` / `callBoth()` / `call(_:)` 这几段原样不动，**只有 `fetchMembership()` 里的 `Self.isLoggedIn = false` 要改成 `isLoggedIn = false`**（去掉 `Self.`，因为不再是 static）。

`presentLogin()` 和 `logout()` 改成：

```swift
    func presentLogin() async {
        let loginWV = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 680),
                                configuration: {
                                    let c = WKWebViewConfiguration()
                                    c.websiteDataStore = dataStore
                                    return c
                                }())
        loginWV.customUserAgent = webView.customUserAgent
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "登录 Kimi"
        window.isReleasedWhenClosed = false
        window.contentView = loginWV
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        loginWV.load(URLRequest(url: URL(string: "https://www.kimi.com/")!))

        for _ in 0..<300 {
            try? await Task.sleep(for: .seconds(1))
            if window.isVisible == false { break }
            if let tok = (try? await loginWV.evaluateJavaScript(
                "localStorage.getItem('access_token')")) as? String, !tok.isEmpty {
                isLoggedIn = true
                for _ in 0..<3 {
                    await load(membershipHome, in: webView)
                    if await readAccessToken(in: webView)?.isEmpty == false { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                break
            }
        }
        window.close()
    }

    func logout() async {
        isLoggedIn = false
        let store = dataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let kimi = records.filter { $0.displayName.localizedCaseInsensitiveContains("kimi") }
        await store.removeData(ofTypes: types, for: kimi)
        await load(URL(string: "about:blank")!, in: webView)
    }
}
```

（`LoadDelegate` 类原样不动。）

- [ ] **Step 2: 修 `AppModel.swift` 里唯一引用旧 `KimiWebSession.isLoggedIn`（static）的地方**

`Sources/QuotaPeek/App/AppModel.swift:180-182`，原来：

```swift
    func kimiWebIsLoggedIn() -> Bool {
        KimiWebSession.isLoggedIn
    }
```

改成：

```swift
    func kimiWebIsLoggedIn() -> Bool {
        KimiWebSession.shared.isLoggedIn
    }
```

- [ ] **Step 3: 修 `ProviderFactory.swift` 里同样的引用**

`Sources/QuotaPeek/Providers/ProviderFactory.swift`，原来：

```swift
        if preferences.kimiEnabled {
            if KimiWebSession.isLoggedIn {
                probes.append(KimiWebProbe())
            } else {
                probes.append(KimiProbe(executablePath: preferences.kimiExecutable))
            }
        }
```

改成：

```swift
        if preferences.kimiEnabled {
            if KimiWebSession.shared.isLoggedIn {
                probes.append(KimiWebProbe())
            } else {
                probes.append(KimiProbe(executablePath: preferences.kimiExecutable))
            }
        }
```

- [ ] **Step 4: 编译确认通过**

Run: `swift build`
Expected: 编译成功，无警告。

- [ ] **Step 5: 跑全量测试确认零回归**

Run: `swift test`
Expected: 全部 PASS（这一步没有新增测试，纯重构）。

- [ ] **Step 6: 手工冒烟（可选但建议）**

```bash
./scripts/build-app.sh && open dist/QuotaPeek.app
```
在设置里确认 Kimi 网页登录/退出登录按钮行为和改动前一致。

- [ ] **Step 7: Commit**

```bash
git add Sources/QuotaPeek/Infrastructure/KimiWebSession.swift Sources/QuotaPeek/App/AppModel.swift Sources/QuotaPeek/Providers/ProviderFactory.swift
git commit -m "refactor: KimiWebSession 支持按 data store 参数化，为多账号做准备"
```

---

### Task 6: CLI 探针支持自定义登录目录

**Files:**
- Modify: `Sources/QuotaPeek/Providers/ClaudeProbe.swift:1-43`
- Modify: `Sources/QuotaPeek/Providers/CodexProbe.swift:1-35`
- Modify: `Sources/QuotaPeek/Providers/KimiProbe.swift:1-35`
- Test: `Tests/QuotaPeekTests/ProbeEnvironmentTests.swift`（新建）

**Interfaces:**
- Consumes: 无。
- Produces: 三个探针的 `init` 都新增 `homeDirectory: String = ""` 参数（默认值保证 `Tests/QuotaPeekTests/LiveProbeTests.swift` 里现成的 `CodexProbe(executablePath:)` 等调用不用改）。三个探针各暴露一个 `internal static func environmentOverrides(homeDirectory: String) -> [String: String]` 纯函数，把"要不要设置 `CLAUDE_CONFIG_DIR`/`CODEX_HOME`/`KIMI_CODE_HOME`"这段逻辑抽出来单测（`fetch()` 本身会真的起进程，不适合单测，这层是本任务唯一可测的部分）。

**背景**：Claude Code / Codex / Kimi Code 三个 CLI 都认环境变量重定向登录目录（`CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `KIMI_CODE_HOME`，见设计文档"可行性确认"一节）。`homeDirectory` 空串时不设置对应环境变量，等价于让 CLI 用它自己的默认目录——这是保证旧版单账号用户升级后**不用重新登录**的关键。

- [ ] **Step 1: 写测试（先失败）**

```swift
import XCTest
@testable import QuotaPeek

final class ProbeEnvironmentTests: XCTestCase {
    func testClaudeEnvironmentClearsAPIKeysAndSetsConfigDirWhenGiven() {
        let overrides = ClaudeProbe.environmentOverrides(homeDirectory: "/tmp/quota-peek-acct")
        XCTAssertEqual(overrides["ANTHROPIC_API_KEY"], "")
        XCTAssertEqual(overrides["ANTHROPIC_AUTH_TOKEN"], "")
        XCTAssertEqual(overrides["ANTHROPIC_BASE_URL"], "")
        XCTAssertEqual(overrides["CLAUDE_CONFIG_DIR"], "/tmp/quota-peek-acct")
    }

    func testClaudeEnvironmentOmitsConfigDirWhenEmpty() {
        let overrides = ClaudeProbe.environmentOverrides(homeDirectory: "")
        XCTAssertNil(overrides["CLAUDE_CONFIG_DIR"], "空串代表沿用 CLI 自己的默认目录，不应该设置成空字符串环境变量")
    }

    func testCodexEnvironmentSetsHomeWhenGiven() {
        XCTAssertEqual(CodexProbe.environmentOverrides(homeDirectory: "/tmp/x")["CODEX_HOME"], "/tmp/x")
        XCTAssertNil(CodexProbe.environmentOverrides(homeDirectory: "")["CODEX_HOME"])
    }

    func testKimiEnvironmentSetsHomeWhenGiven() {
        XCTAssertEqual(KimiProbe.environmentOverrides(homeDirectory: "/tmp/y")["KIMI_CODE_HOME"], "/tmp/y")
        XCTAssertNil(KimiProbe.environmentOverrides(homeDirectory: "")["KIMI_CODE_HOME"])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ProbeEnvironmentTests`
Expected: FAIL —— `environmentOverrides` 还不存在。

- [ ] **Step 3: 改 `ClaudeProbe.swift`**

把 1-43 行改成：

```swift
import Foundation

struct ClaudeProbe: ProviderProbe {
    let provider: ProviderID = .claude
    let source: SnapshotSource = .cli

    private let executablePath: String
    private let homeDirectory: String
    private let runner = ProcessRunner()

    init(executablePath: String, homeDirectory: String = "") {
        self.executablePath = executablePath
        self.homeDirectory = homeDirectory
    }

    static func environmentOverrides(homeDirectory: String) -> [String: String] {
        var overrides = ["ANTHROPIC_API_KEY": "", "ANTHROPIC_AUTH_TOKEN": "", "ANTHROPIC_BASE_URL": ""]
        if !homeDirectory.isEmpty { overrides["CLAUDE_CONFIG_DIR"] = homeDirectory }
        return overrides
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let executable = CommandLocator.locate("claude", explicitPath: executablePath) else {
            throw ProbeError.executableNotFound("Claude Code")
        }
        let workingDirectory = try probeWorkingDirectory()

        let result = try await runner.run(
            executable: executable,
            arguments: ["/usage", "--allowed-tools", "", "--ax-screen-reader"],
            input: "\r",
            timeout: 14,
            pseudoTerminal: true,
            closeInput: false,
            inputDelay: 0.2,
            inputReadyText: "Quick safety check",
            inputReadyTimeout: 5,
            skipInputIfNotReady: true,
            workingDirectory: workingDirectory,
            environment: Self.environmentOverrides(homeDirectory: homeDirectory)
        )

        if result.timedOut && result.text.isEmpty {
            throw ProbeError.timedOut("Claude")
        }
        return try ClaudeUsageParser.parse(result.text)
    }

    private func probeWorkingDirectory() throws -> URL {
```

（`probeWorkingDirectory()` 方法体本身以及后面的 `ClaudeUsageParser` 原样不动。）

- [ ] **Step 4: 改 `CodexProbe.swift`**

把开头改成：

```swift
import Foundation

struct CodexProbe: ProviderProbe {
    let provider: ProviderID = .codex
    let source: SnapshotSource = .localRPC

    private let executablePath: String
    private let homeDirectory: String
    private let runner = ProcessRunner()

    init(executablePath: String, homeDirectory: String = "") {
        self.executablePath = executablePath
        self.homeDirectory = homeDirectory
    }

    static func environmentOverrides(homeDirectory: String) -> [String: String] {
        homeDirectory.isEmpty ? [:] : ["CODEX_HOME": homeDirectory]
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let executable = CommandLocator.locate("codex", explicitPath: executablePath) else {
            throw ProbeError.executableNotFound("Codex CLI")
        }

        let messages = [
            #"{"method":"initialize","id":1,"params":{"clientInfo":{"name":"quota-peek","title":"QuotaPeek","version":"0.1.0"},"capabilities":{"experimentalApi":false}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"method":"account/rateLimits/read","id":2}"#
        ].joined(separator: "\n") + "\n"

        let result = try await runner.run(
            executable: executable,
            arguments: ["-s", "read-only", "-a", "untrusted", "app-server"],
            input: messages,
            timeout: 4,
            closeInput: false,
            environment: Self.environmentOverrides(homeDirectory: homeDirectory)
        )

        if result.timedOut && result.text.isEmpty {
            throw ProbeError.timedOut("Codex")
        }
        return try CodexRateLimitsParser.parse(result.text)
    }
}
```

（`enum CodexRateLimitsParser { ... }` 整段原样不动，紧接着写在后面。）

- [ ] **Step 5: 改 `KimiProbe.swift`**

把开头改成：

```swift
import Foundation

struct KimiProbe: ProviderProbe {
    let provider: ProviderID = .kimi
    let source: SnapshotSource = .cli

    private let executablePath: String
    private let homeDirectory: String
    private let runner = ProcessRunner()

    init(executablePath: String, homeDirectory: String = "") {
        self.executablePath = executablePath
        self.homeDirectory = homeDirectory
    }

    static func environmentOverrides(homeDirectory: String) -> [String: String] {
        homeDirectory.isEmpty ? [:] : ["KIMI_CODE_HOME": homeDirectory]
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let executable = CommandLocator.locate("kimi", explicitPath: executablePath) else {
            throw ProbeError.executableNotFound("Kimi CLI")
        }

        let result = try await runner.run(
            executable: executable,
            arguments: [],
            input: "/usage\r",
            timeout: 14,
            pseudoTerminal: true,
            closeInput: false,
            inputDelay: 0.2,
            inputReadyText: "Send /help for help information.",
            inputReadyTimeout: 8,
            environment: Self.environmentOverrides(homeDirectory: homeDirectory)
        )

        if result.timedOut && result.text.isEmpty {
            throw ProbeError.timedOut("Kimi")
        }
        return try KimiUsageParser.parse(result.text)
    }
}
```

（`enum KimiUsageParser { ... }` 整段原样不动。）

- [ ] **Step 6: 跑测试确认通过**

Run: `swift test --filter ProbeEnvironmentTests`
Expected: 4 个测试 PASS。

- [ ] **Step 7: 全量测试 + 编译 `LiveProbeTests.swift` 确认零回归**

Run: `swift build && swift test`
Expected: 全部 PASS。`Tests/QuotaPeekTests/LiveProbeTests.swift` 里 `CodexProbe(executablePath: ...)` 等调用因为 `homeDirectory` 有默认值，不用改代码就能继续编译。

- [ ] **Step 8: Commit**

```bash
git add Sources/QuotaPeek/Providers/ClaudeProbe.swift Sources/QuotaPeek/Providers/CodexProbe.swift Sources/QuotaPeek/Providers/KimiProbe.swift Tests/QuotaPeekTests/ProbeEnvironmentTests.swift
git commit -m "feat: CLI 探针支持通过环境变量重定向登录目录"
```

---

### Task 7: 拉起 Terminal 完成 CLI 登录

**Files:**
- Create: `Sources/QuotaPeek/Infrastructure/TerminalLauncher.swift`
- Test: `Tests/QuotaPeekTests/TerminalLauncherTests.swift`（新建）

**Interfaces:**
- Consumes: 无。
- Produces: `TerminalLauncher.appleScript(for: String) -> String`（纯函数，可测）、`TerminalLauncher.run(command: String)`（真的调用 `osascript` 拉起 Terminal.app，副作用，不单测）、`TerminalLauncher.loginCommand(provider: ProviderID, homeDirectory: String) -> String`（拼三家各自的登录命令）。Task 10 会调用 `run(command:)` 和 `loginCommand(provider:homeDirectory:)`。

- [ ] **Step 1: 写测试（先失败）**

```swift
import XCTest
@testable import QuotaPeek

final class TerminalLauncherTests: XCTestCase {
    func testAppleScriptEscapesDoubleQuotes()  {
        let script = TerminalLauncher.appleScript(for: #"echo "hi""#)
        XCTAssertTrue(script.contains(#"echo \"hi\""#), "命令里的双引号必须转义，否则 AppleScript 字符串会提前截断")
    }

    func testAppleScriptWrapsInTerminalTellBlock() {
        let script = TerminalLauncher.appleScript(for: "echo hi")
        XCTAssertTrue(script.contains("tell application \"Terminal\""))
        XCTAssertTrue(script.contains("do script \"echo hi\""))
    }

    func testLoginCommandPerProvider() {
        XCTAssertEqual(
            TerminalLauncher.loginCommand(provider: .claude, homeDirectory: "/tmp/a"),
            #"CLAUDE_CONFIG_DIR="/tmp/a" claude"#
        )
        XCTAssertEqual(
            TerminalLauncher.loginCommand(provider: .codex, homeDirectory: "/tmp/b"),
            #"CODEX_HOME="/tmp/b" codex login"#
        )
        XCTAssertEqual(
            TerminalLauncher.loginCommand(provider: .kimi, homeDirectory: "/tmp/c"),
            #"KIMI_CODE_HOME="/tmp/c" kimi login"#
        )
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter TerminalLauncherTests`
Expected: FAIL —— `TerminalLauncher` 还不存在。

- [ ] **Step 3: 写实现**

```swift
import Foundation

/// 新增 CLI 类账号时需要用户实际登录一次；不在应用内自动化这段交互
/// （各家 CLI 登录流程不一样、大多涉及浏览器跳转，硬编码自动化脆弱），
/// 而是拉起系统 Terminal.app 让用户像平时一样登录，交互交给 CLI 自己处理。
enum TerminalLauncher {
    static func loginCommand(provider: ProviderID, homeDirectory: String) -> String {
        switch provider {
        case .claude: #"CLAUDE_CONFIG_DIR="\#(homeDirectory)" claude"#
        case .codex:  #"CODEX_HOME="\#(homeDirectory)" codex login"#
        case .kimi:   #"KIMI_CODE_HOME="\#(homeDirectory)" kimi login"#
        case .glm, .grok: ""  // 非 CLI 类型，调用方不应该传进来
        }
    }

    static func appleScript(for command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
    }

    /// 副作用：真的拉起 Terminal.app。失败静默——用户可以自己开 Terminal 手动敲命令。
    static func run(command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript(for: command)]
        try? process.run()
    }
}
```

（注意 `replacingOccurrences(of: "\\", ...)` 必须写在转义双引号**之前**，否则会把双引号转义后新加的反斜杠又转义一遍。）

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter TerminalLauncherTests`
Expected: 3 个测试 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/QuotaPeek/Infrastructure/TerminalLauncher.swift Tests/QuotaPeekTests/TerminalLauncherTests.swift
git commit -m "feat: 新增 TerminalLauncher，拉起 Terminal 完成 CLI 账号登录"
```

---

### Task 8: `ProviderFactory` 新增按账号构造探针的重载

**Files:**
- Modify: `Sources/QuotaPeek/Providers/ProviderFactory.swift`（新增一个 `extension`，旧的 `make(preferences:...)` 原样保留）
- Modify: `Sources/QuotaPeek/Providers/KimiWebProbe.swift:1-11`（`KimiWebProbe` 加 `session` 参数，默认 `.shared`，向后兼容）
- Test: `Tests/QuotaPeekTests/ProviderFactoryTests.swift`（新建）

**Interfaces:**
- Consumes: `ProviderAccount`（Task 1）、探针的 `homeDirectory` 参数（Task 6）、`KimiWebSession`（Task 5）。
- Produces: `ProviderFactory.make(accounts:executablePaths:secret:kimiWebSession:) -> [(account: ProviderAccount, probe: any ProviderProbe)]`。Task 9 会改 `AppModel` 调用这个新重载，并删掉旧的 `make(preferences:glmAPIKey:grokCookie:)`。

**背景**：CLI 可执行文件路径（`codexExecutable`/`claudeExecutable`/`kimiExecutable`）是"一个 Provider 一条路径"的全局设置，跟登录目录（账号维度）是两回事，所以单独用一个 tuple 参数传入，不塞进 `ProviderAccount`。

- [ ] **Step 1: 写测试（先失败）**

```swift
import XCTest
@testable import QuotaPeek

final class ProviderFactoryTests: XCTestCase {
    func testBuildsOneProbePerEnabledAccountAndSkipsDisabled() {
        let claude = ProviderAccount(id: UUID(), provider: .claude, label: "工作", credential: .cliHome(path: "/tmp/a"), enabled: true)
        let disabledCodex = ProviderAccount(id: UUID(), provider: .codex, label: "默认", credential: .cliHome(path: ""), enabled: false)
        let grok = ProviderAccount(id: UUID(), provider: .grok, label: "默认", credential: .cookie, enabled: true)

        let pairs = ProviderFactory.make(
            accounts: [claude, disabledCodex, grok],
            executablePaths: (codex: "", claude: "", kimi: ""),
            secret: { _ in nil },
            kimiWebSession: { _ in KimiWebSession.shared }
        )

        XCTAssertEqual(pairs.count, 2, "禁用的账号不应该产出探针")
        XCTAssertEqual(Set(pairs.map(\.account.id)), Set([claude.id, grok.id]))
        XCTAssertTrue(pairs.contains { $0.probe is ClaudeProbe })
        XCTAssertTrue(pairs.contains { $0.probe is GrokProbe })
    }

    func testKimiPicksWebProbeWhenAccountIsLoggedIn() {
        let loggedInSession = KimiWebSession(dataStore: .default(), loginFlagKey: "test.kimi.loggedin.\(UUID())")
        loggedInSession.isLoggedIn = true
        let account = ProviderAccount(id: UUID(), provider: .kimi, label: "默认", credential: .kimi(cliHomePath: ""), enabled: true)

        let pairs = ProviderFactory.make(
            accounts: [account],
            executablePaths: (codex: "", claude: "", kimi: ""),
            secret: { _ in nil },
            kimiWebSession: { _ in loggedInSession }
        )

        XCTAssertEqual(pairs.count, 1)
        XCTAssertTrue(pairs[0].probe is KimiWebProbe)
    }

    func testKimiFallsBackToCLIProbeWhenNotLoggedIn() {
        let loggedOutSession = KimiWebSession(dataStore: .default(), loginFlagKey: "test.kimi.loggedout.\(UUID())")
        let account = ProviderAccount(id: UUID(), provider: .kimi, label: "默认", credential: .kimi(cliHomePath: ""), enabled: true)

        let pairs = ProviderFactory.make(
            accounts: [account],
            executablePaths: (codex: "", claude: "", kimi: ""),
            secret: { _ in nil },
            kimiWebSession: { _ in loggedOutSession }
        )

        XCTAssertEqual(pairs.count, 1)
        XCTAssertTrue(pairs[0].probe is KimiProbe)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ProviderFactoryTests`
Expected: FAIL —— 新重载和 `KimiWebProbe(session:)` 都还不存在。

- [ ] **Step 3: 改 `KimiWebProbe.swift`**

原文件：

```swift
struct KimiWebProbe: ProviderProbe {
    let provider: ProviderID = .kimi
    let source: SnapshotSource = .officialAPI

    func fetch() async throws -> ProviderSnapshot {
        let (stats, sub) = try await KimiWebSession.shared.fetchMembership()
        return try KimiMembershipParser.parse(stats: stats, subscription: sub)
    }
}
```

改成：

```swift
struct KimiWebProbe: ProviderProbe {
    let provider: ProviderID = .kimi
    let source: SnapshotSource = .officialAPI
    let session: KimiWebSession

    init(session: KimiWebSession = .shared) {
        self.session = session
    }

    func fetch() async throws -> ProviderSnapshot {
        let (stats, sub) = try await session.fetchMembership()
        return try KimiMembershipParser.parse(stats: stats, subscription: sub)
    }
}
```

（`enum KimiMembershipParser { ... }` 原样不动。因为 `KimiWebSession` 是 `@MainActor` 类，`KimiWebProbe` 持有它作为存储属性会让 `KimiWebProbe` 整体隐式要求 `@MainActor` 上下文才能构造/调用——这跟它现在的调用方式（`AppModel`，本来就是 `@MainActor`）一致，不会引入新问题。）

- [ ] **Step 4: 在 `ProviderFactory.swift` 追加新重载**

在文件末尾（`enum ProviderFactory { ... }` 闭合大括号之后）追加：

```swift

extension ProviderFactory {
    @MainActor
    static func make(
        accounts: [ProviderAccount],
        executablePaths: (codex: String, claude: String, kimi: String),
        secret: (ProviderAccount) -> String?,
        kimiWebSession: (ProviderAccount) -> KimiWebSession
    ) -> [(account: ProviderAccount, probe: any ProviderProbe)] {
        accounts.filter(\.enabled).compactMap { account -> (account: ProviderAccount, probe: any ProviderProbe)? in
            switch (account.provider, account.credential) {
            case (.codex, .cliHome(let path)):
                return (account, CodexProbe(executablePath: executablePaths.codex, homeDirectory: path))
            case (.claude, .cliHome(let path)):
                return (account, ClaudeProbe(executablePath: executablePaths.claude, homeDirectory: path))
            case (.kimi, .kimi(let cliHomePath)):
                let session = kimiWebSession(account)
                if session.isLoggedIn {
                    return (account, KimiWebProbe(session: session))
                }
                return (account, KimiProbe(executablePath: executablePaths.kimi, homeDirectory: cliHomePath))
            case (.glm, .apiKey(let baseURL)):
                return (account, GLMProbe(baseURL: baseURL, apiKey: secret(account)))
            case (.grok, .cookie):
                return (account, GrokProbe(cookie: secret(account)))
            default:
                return nil // provider/credential 类型不匹配，理论上不会出现，防御性处理
            }
        }
    }
}
```

`@MainActor` 标注是因为 `kimiWebSession(account)` 返回的 `KimiWebSession` 是 `@MainActor` 类型，读它的 `isLoggedIn` 需要 MainActor 上下文——这个函数本来就只从 `AppModel`（`@MainActor`）里同步调用，标注只是让编译器认可这个既有前提，不改变实际执行时机。

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter ProviderFactoryTests`
Expected: 3 个测试 PASS。

- [ ] **Step 6: 全量测试确认零回归**

Run: `swift build && swift test`
Expected: 全部 PASS（旧的 `ProviderFactory.make(preferences:...)` 重载和 `KimiWebProbe()` 无参构造都还在，`AppModel` 尚未切换，继续用旧重载）。

- [ ] **Step 7: Commit**

```bash
git add Sources/QuotaPeek/Providers/ProviderFactory.swift Sources/QuotaPeek/Providers/KimiWebProbe.swift Tests/QuotaPeekTests/ProviderFactoryTests.swift
git commit -m "feat: ProviderFactory 新增按账号构造探针的重载"
```

---

### Task 9: `AppModel` 切到账号模型（核心重连线）

**Files:**
- Modify: `Sources/QuotaPeek/Domain/Models.swift:235-240`（`ProviderResult`）
- Modify: `Sources/QuotaPeek/App/AppModel.swift`（大改：`baseSnapshots`/`recommendedProvider`/`visibleSnapshots`/`refreshAll`/`fetchResult`/`fetchCLIResult`，删掉私有推荐算法）
- Modify: `Sources/QuotaPeek/UI/DashboardViews.swift`（`model.recommendedProvider` → `model.recommendedAccountID`，`ProviderCard` 加账号标签后缀）

**Interfaces:**
- Consumes: `Recommendation`（Task 3）、`AppPreferences.accounts`（Task 4）、`ProviderFactory.make(accounts:...)`（Task 8）。
- Produces: `AppModel.recommendedAccountID: UUID?`（替换原 `recommendedProvider: ProviderID?`）；`AppModel.visibleSnapshots`/`overallRemainingPercent`/`menuBarSymbol` 行为不变，但底层驱动数据变成账号而不是固定 5 个 Provider。

**过渡态说明**：这一步之后到 Task 11（`AccountListSection`）完成之前，设置页仍然显示旧版 Toggle/路径输入框（`SettingsView.swift` 本任务不碰），但这些控件已经不再影响实际探针——因为 `AppModel` 已经改读 `preferences.accounts`。这是刻意接受的短暂过渡态，只存在于接下来两三个任务之间，不会对外发布；Task 11 会换成真正的账号列表 UI。

**本任务没有新增自动化测试**——`AppModel` 是 `@MainActor` 单例、构造时会碰 Keychain/UserDefaults/`FloatingPanelManager`，本仓库一直没有为它写单测（核心算法已经在 Task 3 挪成纯函数单测过了）。验收靠 `swift build` 全绿 + 手工冒烟。

- [ ] **Step 1: 改 `ProviderResult`**

`Sources/QuotaPeek/Domain/Models.swift:235-240`，原来：

```swift
struct ProviderResult: Sendable {
    let provider: ProviderID
    let snapshot: ProviderSnapshot?
    let errorMessage: String?
    let source: SnapshotSource
}
```

改成：

```swift
struct ProviderResult: Sendable {
    let account: ProviderAccount
    let snapshot: ProviderSnapshot?
    let errorMessage: String?
    let source: SnapshotSource
}
```

- [ ] **Step 2: 重写 `AppModel.swift` 的数据/推荐/刷新部分**

把 35-98 行（`enabledProviders` 到 `menuBarSymbol` 结束）替换为：

```swift
    var executablePaths: (codex: String, claude: String, kimi: String) {
        (preferences.codexExecutable, preferences.claudeExecutable, preferences.kimiExecutable)
    }

    private var baseSnapshots: [ProviderSnapshot] {
        preferences.accounts.filter(\.enabled).map { account -> ProviderSnapshot in
            if let snapshot = snapshots.first(where: { $0.accountID == account.id }) {
                return snapshot
            }
            return .failure(
                accountID: account.id,
                provider: account.provider,
                label: account.label,
                message: isRefreshing ? "正在查询…" : "等待首次查询",
                source: defaultSource(for: account.provider)
            )
        }
    }

    var recommendedAccountID: UUID? {
        Recommendation.recommendedAccountID(among: baseSnapshots)
    }

    var visibleSnapshots: [ProviderSnapshot] {
        let base = baseSnapshots
        guard let recommended = recommendedAccountID,
              let index = base.firstIndex(where: { $0.accountID == recommended }), index != 0 else {
            return base
        }
        var reordered = base
        reordered.insert(reordered.remove(at: index), at: 0)
        return reordered
    }

    var overallRemainingPercent: Double? {
        visibleSnapshots.compactMap(\.minimumRemainingPercent).min()
    }

    var menuBarSymbol: String {
        guard let remaining = overallRemainingPercent else { return "gauge.with.dots.needle.0percent" }
        if remaining <= 10 { return "gauge.with.dots.needle.100percent" }
        if remaining <= 25 { return "gauge.with.dots.needle.67percent" }
        return "gauge.with.dots.needle.33percent"
    }
```

（`enabledProviders` 这个计算属性整个删掉——本仓库其它地方目前没有别处引用它；如果 grep 后发现还有引用，把那处也一并改成 `preferences.accounts.filter(\.enabled).map(\.provider)`。）

- [ ] **Step 3: 重写 `refreshAll()`**

原来的 `refreshAll()`（大致在 112-169 行）整体替换为：

```swift
    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let currentPreferences = preferences
        let pairs = ProviderFactory.make(
            accounts: currentPreferences.accounts,
            executablePaths: executablePaths,
            secret: { [weak self] account in
                guard let key = account.keychainKey else { return nil }
                return self?.secretOverride(for: account) ?? SecretStore.read(account: key)
            },
            kimiWebSession: { [weak self] account in
                self?.kimiWebSession(for: account) ?? .shared
            }
        )

        let cliPairs = pairs.filter { $0.probe.source == .cli }
        let independentPairs = pairs.filter { $0.probe.source != .cli }
        let results = await withTaskGroup(of: [ProviderResult].self, returning: [ProviderResult].self) { group in
            struct HomeDirectoryGroupKey: Hashable {
                let provider: ProviderID
                let homeDirectory: String
            }
            let cliGroups = Dictionary(grouping: cliPairs) { pair in
                HomeDirectoryGroupKey(
                    provider: pair.account.provider,
                    homeDirectory: pair.account.credential.cliHomeDirectory ?? ""
                )
            }
            for (_, groupPairs) in cliGroups {
                group.addTask {
                    var batch: [ProviderResult] = []
                    for pair in groupPairs {
                        batch.append(await Self.fetchCLIResult(from: pair.probe, account: pair.account))
                    }
                    return batch
                }
            }
            for pair in independentPairs {
                group.addTask { [await Self.fetchResult(from: pair.probe, account: pair.account)] }
            }

            var collected: [ProviderResult] = []
            for await batch in group { collected.append(contentsOf: batch) }
            return collected
        }

        let accountsByID = Dictionary(uniqueKeysWithValues: currentPreferences.accounts.map { ($0.id, $0) })
        var updated = snapshots.filter { snapshot in
            guard let account = accountsByID[snapshot.accountID] else { return false } // 账号已被删除，丢弃缓存
            return !account.enabled // 保留当前被禁用账号的缓存；启用的账号本轮会有新结果覆盖
        }
        for result in results {
            if var snapshot = result.snapshot {
                snapshot.accountID = result.account.id
                snapshot.account = result.account.label
                updated.append(snapshot)
                if preferences.notificationsEnabled {
                    NotificationManager.notifyIfNeeded(snapshot: snapshot, threshold: Double(preferences.notificationThreshold))
                }
            } else {
                let previous = snapshots.first(where: { $0.accountID == result.account.id })
                updated.append(.failure(
                    accountID: result.account.id,
                    provider: result.account.provider,
                    label: result.account.label,
                    message: result.errorMessage ?? "未知错误",
                    source: result.source,
                    previous: previous
                ))
            }
        }

        snapshots = updated
        lastRefreshAt = Date()
        SnapshotStore.save(snapshots)
    }
```

`secretOverride(for:)` 是给 Task 10 预留的扩展点（那里会加真正的 Keychain 读取封装）；本任务先给一个占位实现，紧接着加在 `refreshAll()` 后面：

```swift
    private func secretOverride(for account: ProviderAccount) -> String? { nil }

    private func kimiWebSession(for account: ProviderAccount) -> KimiWebSession {
        if account.provider != .kimi { return .shared }
        return .shared // Task 10 会换成按账号 UUID 找/建 KimiWebSession 实例
    }
```

- [ ] **Step 4: 删掉旧的私有推荐算法**

删掉原来 70-87 行的 `private static func recommendedProvider(among:)` 和 `private static func recommendationScore(for:now:)`——已经在 Step 2/3 里被 `Recommendation.recommendedAccountID` 取代。

- [ ] **Step 5: 改 `fetchResult`/`fetchCLIResult` 签名**

原来（239-262 行）：

```swift
    nonisolated private static func fetchResult(from probe: any ProviderProbe) async -> ProviderResult {
        do {
            return ProviderResult(
                provider: probe.provider,
                snapshot: try await probe.fetch(),
                errorMessage: nil,
                source: probe.source
            )
        } catch {
            return ProviderResult(
                provider: probe.provider,
                snapshot: nil,
                errorMessage: error.localizedDescription,
                source: probe.source
            )
        }
    }

    nonisolated private static func fetchCLIResult(from probe: any ProviderProbe) async -> ProviderResult {
        let first = await fetchResult(from: probe)
        guard first.snapshot == nil else { return first }
        try? await Task.sleep(for: .seconds(1))
        return await fetchResult(from: probe)
    }
```

改成：

```swift
    nonisolated private static func fetchResult(from probe: any ProviderProbe, account: ProviderAccount) async -> ProviderResult {
        do {
            return ProviderResult(
                account: account,
                snapshot: try await probe.fetch(),
                errorMessage: nil,
                source: probe.source
            )
        } catch {
            return ProviderResult(
                account: account,
                snapshot: nil,
                errorMessage: error.localizedDescription,
                source: probe.source
            )
        }
    }

    nonisolated private static func fetchCLIResult(from probe: any ProviderProbe, account: ProviderAccount) async -> ProviderResult {
        let first = await fetchResult(from: probe, account: account)
        guard first.snapshot == nil else { return first }
        try? await Task.sleep(for: .seconds(1))
        return await fetchResult(from: probe, account: account)
    }
```

- [ ] **Step 6: 改通知去重 key**

`NotificationManager.notifyIfNeeded`（文件末尾）里原来：

```swift
        let key = "QuotaPeek.notice.\(snapshot.provider.rawValue).\(band).\(resetKey)"
```

改成：

```swift
        let key = "QuotaPeek.notice.\(snapshot.accountID.uuidString).\(band).\(resetKey)"
```

（改这一行是因为同一个 Provider 现在可能有多个账号，去重 key 必须按账号区分，否则两个账号的低额度提醒会互相吞掉。）

- [ ] **Step 7: 修 `DashboardViews.swift` 里唯一引用 `recommendedProvider` 的地方**

`Sources/QuotaPeek/UI/DashboardViews.swift` 里 `ProviderCards`（`ForEach(model.visibleSnapshots) { snapshot in ProviderCard(snapshot: snapshot, isRecommended: snapshot.provider == model.recommendedProvider) }`）改成：

```swift
struct ProviderCards: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let accountCounts = Dictionary(grouping: model.visibleSnapshots, by: \.provider).mapValues(\.count)
        LazyVStack(spacing: 7) {
            ForEach(model.visibleSnapshots) { snapshot in
                ProviderCard(
                    snapshot: snapshot,
                    isRecommended: snapshot.accountID == model.recommendedAccountID,
                    showsAccountLabel: (accountCounts[snapshot.provider] ?? 0) > 1
                )
            }
        }
    }
}
```

`ProviderCard` 加一个 `showsAccountLabel: Bool` 属性，标题那行（`Text(snapshot.provider.displayName)...`）后面追加：

```swift
                if showsAccountLabel, let label = snapshot.account, !label.isEmpty {
                    Text("· \(label)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
```

（单账号 Provider 因为 `accountCounts[...] == 1`，`showsAccountLabel` 是 `false`，视觉上和现在完全一样。）

- [ ] **Step 8: 编译确认通过**

Run: `swift build`
Expected: 编译成功。如果报错说明有遗漏的调用点，按报错逐一修（大概率是 `enabledProviders` 或 `recommendedProvider` 还有别处引用，用 `grep -rn "enabledProviders\|recommendedProvider" Sources/` 排查）。

- [ ] **Step 9: 全量测试确认零回归**

Run: `swift test`
Expected: 全部 PASS。

- [ ] **Step 10: 手工冒烟——确认迁移账号零感升级**

```bash
pkill -f "dist/QuotaPeek.app/Contents/MacOS/QuotaPeek" 2>/dev/null; sleep 1
./scripts/build-app.sh && open dist/QuotaPeek.app
```

打开菜单栏面板，确认：
- 之前启用的 Provider 卡片正常显示数据（不需要重新登录任何 CLI/网页账号）。
- 卡片标题没有多出"· 默认"这种后缀（因为每个 Provider 目前都只有一个账号）。
- 排序/推荐高亮跟改动前观感一致。

- [ ] **Step 11: Commit**

```bash
git add Sources/QuotaPeek/Domain/Models.swift Sources/QuotaPeek/App/AppModel.swift Sources/QuotaPeek/UI/DashboardViews.swift
git commit -m "feat: AppModel 核心逻辑切换到账号模型"
```

---

### Task 10: 账号管理方法（增/删/改名）+ Keychain 迁移

**Files:**
- Modify: `Sources/QuotaPeek/App/AppModel.swift`（新增方法段 + Keychain 迁移调用 + 补全 `secretOverride`/`kimiWebSession(for:)`）
- Test: `Tests/QuotaPeekTests/AccountKeychainMigrationTests.swift`（新建，只测纯谓词部分）

**Interfaces:**
- Consumes: `TerminalLauncher`（Task 7）、`ProviderAccount`/`AccountCredential`（Task 1）。
- Produces: `AppModel.addCLIAccount(provider:label:) throws`、`addCredentialAccount(provider:label:baseURL:)`、`addKimiWebAccount(label:)`、`removeAccount(id:)`、`renameAccount(id:label:)`、`saveSecret(_:for:) throws`、`hasSecret(for:) -> Bool`、`kimiLogin(accountID:) async`、`kimiLogout(accountID:) async`、`kimiWebIsLoggedIn(accountID:) -> Bool`（替换 Task 5 里保留的无参版本）、顶层 `enum KeychainMigration`。Task 11 的 `SettingsView`/`AccountListSection` 直接调这些方法。

- [ ] **Step 1: 写 Keychain 迁移谓词的测试（先失败）**

```swift
import XCTest
@testable import QuotaPeek

final class AccountKeychainMigrationTests: XCTestCase {
    func testMigratesWhenLegacyHasValueAndNewDoesNot() {
        XCTAssertTrue(KeychainMigration.shouldMigrate(legacyValue: "sk-old", newValue: nil))
        XCTAssertTrue(KeychainMigration.shouldMigrate(legacyValue: "sk-old", newValue: ""))
    }

    func testDoesNotMigrateWhenNewAlreadyHasValue() {
        XCTAssertFalse(KeychainMigration.shouldMigrate(legacyValue: "sk-old", newValue: "sk-new"))
    }

    func testDoesNotMigrateWhenLegacyIsEmpty() {
        XCTAssertFalse(KeychainMigration.shouldMigrate(legacyValue: nil, newValue: nil))
        XCTAssertFalse(KeychainMigration.shouldMigrate(legacyValue: "", newValue: nil))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AccountKeychainMigrationTests`
Expected: FAIL —— `KeychainMigration` 还不存在。

- [ ] **Step 3: 在 `AppModel.swift` 顶层（`final class AppModel` 之外）加 `KeychainMigration`**

```swift
/// 判断某个旧固定 Keychain key 是否需要搬到账号专属的新 key：
/// 旧 key 有值、且新 key 还没有值。纯谓词，脱离 Keychain I/O 单独可测。
enum KeychainMigration {
    static func shouldMigrate(legacyValue: String?, newValue: String?) -> Bool {
        let legacyHasValue = legacyValue?.isEmpty == false
        let newHasValue = newValue?.isEmpty == false
        return legacyHasValue && !newHasValue
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AccountKeychainMigrationTests`
Expected: 3 个测试 PASS。

- [ ] **Step 5: 在 `AppModel` 里补齐账号管理方法**

在 `class AppModel` 内部（`saveGrokCookie`/`hasGrokCookie` 附近，替换掉原来的 `saveGLMAPIKey`/`hasGLMAPIKey`/`kimiWebIsLoggedIn`/`kimiLogin`/`kimiLogout`/`saveGrokCookie`/`hasGrokCookie` 这一整段，Task 9 里临时占位的 `secretOverride`/`kimiWebSession(for:)` 也在这一步换成真实实现）：

```swift
    private static let accountsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("QuotaPeek", isDirectory: true)
        .appendingPathComponent("Accounts", isDirectory: true)

    private static let keychainMigrationFlag = "QuotaPeek.migratedAccountKeychain.v1"
    private var kimiWebSessions: [UUID: KimiWebSession] = [:]

    func addCLIAccount(provider: ProviderID, label: String) throws {
        let id = UUID()
        let directory = Self.accountsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let credential: AccountCredential = provider == .kimi
            ? .kimi(cliHomePath: directory.path)
            : .cliHome(path: directory.path)
        preferences.accounts.append(ProviderAccount(id: id, provider: provider, label: label, credential: credential, enabled: true))
        TerminalLauncher.run(command: TerminalLauncher.loginCommand(provider: provider, homeDirectory: directory.path))
    }

    func addCredentialAccount(provider: ProviderID, label: String, baseURL: String = "https://open.bigmodel.cn") {
        let credential: AccountCredential = provider == .glm ? .apiKey(baseURL: baseURL) : .cookie
        preferences.accounts.append(ProviderAccount(id: UUID(), provider: provider, label: label, credential: credential, enabled: true))
    }

    func addKimiWebAccount(label: String) {
        preferences.accounts.append(ProviderAccount(id: UUID(), provider: .kimi, label: label, credential: .kimi(cliHomePath: ""), enabled: true))
    }

    func renameAccount(id: UUID, label: String) {
        guard let index = preferences.accounts.firstIndex(where: { $0.id == id }) else { return }
        preferences.accounts[index].label = label
    }

    func removeAccount(id: UUID) {
        guard let account = preferences.accounts.first(where: { $0.id == id }) else { return }
        switch account.credential {
        case .cliHome(let path) where !path.isEmpty, .kimi(let path) where !path.isEmpty:
            try? FileManager.default.removeItem(atPath: path)
        case .apiKey, .cookie:
            if let key = account.keychainKey { try? SecretStore.save("", account: key) }
        default:
            break
        }
        if account.provider == .kimi {
            kimiWebSessions[id] = nil
            UserDefaults.standard.removeObject(forKey: "QuotaPeek.kimiWebLoggedIn.\(id.uuidString)")
        }
        preferences.accounts.removeAll { $0.id == id }
        snapshots.removeAll { $0.accountID == id }
    }

    func saveSecret(_ value: String, for account: ProviderAccount) throws {
        guard let key = account.keychainKey else { return }
        try SecretStore.save(value.trimmingCharacters(in: .whitespacesAndNewlines), account: key)
    }

    func hasSecret(for account: ProviderAccount) -> Bool {
        guard let key = account.keychainKey else { return false }
        if account.provider == .glm {
            return SecretStore.read(account: key)?.isEmpty == false || GLMCredentialResolver.resolve(explicit: nil)?.isEmpty == false
        }
        return SecretStore.read(account: key)?.isEmpty == false
    }

    private func secretOverride(for account: ProviderAccount) -> String? {
        guard let key = account.keychainKey else { return nil }
        return SecretStore.read(account: key)
    }

    func kimiWebSession(for account: ProviderAccount) -> KimiWebSession {
        if let existing = kimiWebSessions[account.id] { return existing }
        let isLegacyDefault = account.id == ProviderAccount.legacyDefaultID(for: .kimi)
        let dataStore = isLegacyDefault ? WKWebsiteDataStore.default() : WKWebsiteDataStore(forIdentifier: account.id)!
        let flagKey = isLegacyDefault ? KimiWebSession.legacyLoggedInDefaultsKey : "QuotaPeek.kimiWebLoggedIn.\(account.id.uuidString)"
        let session = KimiWebSession(dataStore: dataStore, loginFlagKey: flagKey)
        kimiWebSessions[account.id] = session
        return session
    }

    func kimiWebIsLoggedIn(accountID: UUID) -> Bool {
        guard let account = preferences.accounts.first(where: { $0.id == accountID }) else { return false }
        return kimiWebSession(for: account).isLoggedIn
    }

    func kimiLogin(accountID: UUID) async {
        guard let account = preferences.accounts.first(where: { $0.id == accountID }) else { return }
        await kimiWebSession(for: account).presentLogin()
        objectWillChange.send()
        await refreshAll()
    }

    func kimiLogout(accountID: UUID) async {
        guard let account = preferences.accounts.first(where: { $0.id == accountID }) else { return }
        await kimiWebSession(for: account).logout()
        objectWillChange.send()
        await refreshAll()
    }

    private func migrateLegacyKeychainIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.keychainMigrationFlag) else { return }
        let legacyKeys: [(ProviderID, String)] = [(.glm, "glm-api-key"), (.grok, "grok-cookie")]
        for (provider, legacyKey) in legacyKeys {
            guard let account = preferences.accounts.first(where: { $0.id == ProviderAccount.legacyDefaultID(for: provider) }),
                  let newKey = account.keychainKey else { continue }
            let legacyValue = SecretStore.read(account: legacyKey)
            let newValue = SecretStore.read(account: newKey)
            if KeychainMigration.shouldMigrate(legacyValue: legacyValue, newValue: newValue), let legacyValue {
                try? SecretStore.save(legacyValue, account: newKey)
            }
        }
        UserDefaults.standard.set(true, forKey: Self.keychainMigrationFlag)
    }
```

`WKWebsiteDataStore(forIdentifier:)` 是 failable-looking 但实际上是非 optional 的便利构造器（返回同一 identifier 会拿到同一份持久 store）；如果本地 SDK 版本的签名是 `WKWebsiteDataStore(forIdentifier: UUID) -> WKWebsiteDataStore`（非 optional），把上面那行的 `!` 去掉即可，跑一下 `swift build` 看编译器提示为准。

文件顶部加 `import WebKit`（`WKWebsiteDataStore` 需要）。

- [ ] **Step 6: 在 `start()` 里调用一次性 Keychain 迁移**

`start()` 方法（大致在 100-110 行）里，`scheduleRefresh(immediate: true)` 之前加一行：

```swift
    func start() {
        guard !started else { return }
        started = true
        migrateLegacyKeychainIfNeeded()
        if preferences.notificationsEnabled {
            Task { await NotificationManager.requestAuthorization() }
        }
        if preferences.floatingPanelEnabled {
            FloatingPanelManager.shared.show(model: self)
        }
        scheduleRefresh(immediate: true)
    }
```

- [ ] **Step 7: 把 `refreshAll()` 里 Task 9 留的占位换成真实调用**

`refreshAll()` 里构造 `pairs` 那段，`secret:`/`kimiWebSession:` 闭包简化成：

```swift
        let pairs = ProviderFactory.make(
            accounts: currentPreferences.accounts,
            executablePaths: executablePaths,
            secret: { [weak self] account in self?.secretOverride(for: account) },
            kimiWebSession: { [weak self] account in self?.kimiWebSession(for: account) ?? .shared }
        )
```

删掉 Task 9 里加的占位 `private func kimiWebSession(for account: ProviderAccount) -> KimiWebSession { ... }`（本任务 Step 5 已经加了正式版本，两份重名会编译报错，确认只保留一份）。

- [ ] **Step 8: 编译确认通过**

Run: `swift build`
Expected: 编译成功。

- [ ] **Step 9: 全量测试确认通过**

Run: `swift test`
Expected: 全部 PASS，含新增的 `AccountKeychainMigrationTests`。

- [ ] **Step 10: Commit**

```bash
git add Sources/QuotaPeek/App/AppModel.swift Tests/QuotaPeekTests/AccountKeychainMigrationTests.swift
git commit -m "feat: 账号增删改方法 + Keychain 一次性迁移"
```

---

### Task 11: 设置页账号列表 UI

**Files:**
- Create: `Sources/QuotaPeek/UI/AccountListSection.swift`
- Modify: `Sources/QuotaPeek/UI/SettingsView.swift`（整份重写）

**Interfaces:**
- Consumes: `AppModel` 的账号管理方法（Task 10）。
- Produces: `AccountListSection` 视图组件，`SettingsView` 用它渲染 5 个 Provider 各自的账号列表。

**没有自动化测试**——本仓库现有的 SwiftUI 视图（`DashboardViews.swift`/`SettingsView.swift`）历来没有自动化测试，靠真机构建 + 手工走查验收，这里保持一致。

- [ ] **Step 1: 写 `AccountListSection.swift`**

```swift
import SwiftUI

/// 按 Provider 渲染账号列表：每行一个账号（可改名、可启用/禁用、可删除），
/// 底部一个"添加账号"按钮触发对应 Provider 的新增流程。
struct AccountListSection: View {
    @ObservedObject var model: AppModel
    let provider: ProviderID
    @State private var newAccountLabel = ""
    @State private var showingAddSheet = false

    private var accounts: [ProviderAccount] {
        model.preferences.accounts.filter { $0.provider == provider }
    }

    var body: some View {
        Section(provider.displayName) {
            ForEach(accounts) { account in
                AccountRow(model: model, account: account)
            }
            Button("+ 添加账号") { showingAddSheet = true }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddAccountSheet(model: model, provider: provider, isPresented: $showingAddSheet)
        }
    }
}

private struct AccountRow: View {
    @ObservedObject var model: AppModel
    let account: ProviderAccount
    @State private var label: String

    init(model: AppModel, account: ProviderAccount) {
        self.model = model
        self.account = account
        _label = State(initialValue: account.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("账号名", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.renameAccount(id: account.id, label: label) }
                Toggle("", isOn: Binding(
                    get: { account.enabled },
                    set: { newValue in
                        guard let index = model.preferences.accounts.firstIndex(where: { $0.id == account.id }) else { return }
                        model.preferences.accounts[index].enabled = newValue
                    }
                ))
                .labelsHidden()
                Button(role: .destructive) { model.removeAccount(id: account.id) } label: {
                    Image(systemName: "trash")
                }
            }
            CredentialEditor(model: model, account: account)
        }
        .padding(.vertical, 2)
    }
}

/// 按凭证类型渲染各自的状态/输入控件：CLI 目录只显示状态文案，
/// GLM/Grok 是密钥输入框，Kimi 额外提供"追加网页登录"。
private struct CredentialEditor: View {
    @ObservedObject var model: AppModel
    let account: ProviderAccount
    @State private var secretInput = ""
    @State private var status = ""

    var body: some View {
        switch account.credential {
        case .cliHome:
            Text(statusText).font(.caption).foregroundStyle(.secondary)
        case .kimi:
            HStack {
                Text(model.kimiWebIsLoggedIn(accountID: account.id) ? "已登录（网页接口）" : "未登录（使用官方 CLI）")
                    .font(.caption)
                    .foregroundStyle(model.kimiWebIsLoggedIn(accountID: account.id) ? .green : .secondary)
                Spacer()
                if model.kimiWebIsLoggedIn(accountID: account.id) {
                    Button("退出网页登录") { Task { await model.kimiLogout(accountID: account.id) } }
                } else {
                    Button("登录 Kimi 网页账号") { Task { await model.kimiLogin(accountID: account.id) } }
                }
            }
        case .apiKey(let baseURL):
            VStack(alignment: .leading, spacing: 4) {
                Text("Base URL: \(baseURL)").font(.caption2).foregroundStyle(.secondary)
                HStack {
                    SecureField("API Key（保存在 macOS 钥匙串）", text: $secretInput)
                        .textFieldStyle(.roundedBorder)
                    Button("保存") { save() }
                }
                Text(status.isEmpty ? (model.hasSecret(for: account) ? "已保存凭证" : "尚未配置凭证") : status)
                    .font(.caption).foregroundStyle(model.hasSecret(for: account) ? .green : .secondary)
            }
        case .cookie:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SecureField("grok.com Cookie（保存在 macOS 钥匙串）", text: $secretInput)
                        .textFieldStyle(.roundedBorder)
                    Button("保存") { save() }
                }
                Text(status.isEmpty ? (model.hasSecret(for: account) ? "已保存凭证" : "尚未配置凭证") : status)
                    .font(.caption).foregroundStyle(model.hasSecret(for: account) ? .green : .secondary)
            }
        }
    }

    private var statusText: String {
        model.visibleSnapshots.first { $0.accountID == account.id }?.errorMessage ?? "正常"
    }

    private func save() {
        do {
            try model.saveSecret(secretInput, for: account)
            secretInput = ""
            status = "已保存"
        } catch {
            status = error.localizedDescription
        }
    }
}

private struct AddAccountSheet: View {
    @ObservedObject var model: AppModel
    let provider: ProviderID
    @Binding var isPresented: Bool
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新增 \(provider.displayName) 账号").font(.headline)
            TextField("账号名，如「工作」", text: $label).textFieldStyle(.roundedBorder)
            if isCLIProvider {
                Text("确认后会打开 Terminal，请在里面正常登录一次。").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                Button("添加") { add() }.disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var isCLIProvider: Bool { provider == .codex || provider == .claude || provider == .kimi }

    private func add() {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        switch provider {
        case .codex, .claude:
            try? model.addCLIAccount(provider: provider, label: trimmed)
        case .kimi:
            try? model.addCLIAccount(provider: .kimi, label: trimmed)
        case .glm:
            model.addCredentialAccount(provider: .glm, label: trimmed)
        case .grok:
            model.addCredentialAccount(provider: .grok, label: trimmed)
        }
        isPresented = false
        label = ""
    }
}
```

- [ ] **Step 2: 重写 `SettingsView.swift`**

把原来 5 个 `Section("监控平台")` / `Section("CLI 路径...")` / `Section("Kimi 网页账号")` / `Section("Grok")` / `Section("GLM Coding Plan")` 整段替换为：

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("CLI 路径（留空自动检测）") {
                pathField("Codex", text: $model.preferences.codexExecutable, placeholder: "/opt/homebrew/bin/codex")
                pathField("Claude", text: $model.preferences.claudeExecutable, placeholder: "/opt/homebrew/bin/claude")
                pathField("Kimi", text: $model.preferences.kimiExecutable, placeholder: "~/.local/bin/kimi")
            }

            AccountListSection(model: model, provider: .codex)
            AccountListSection(model: model, provider: .claude)
            AccountListSection(model: model, provider: .kimi)
            AccountListSection(model: model, provider: .glm)
            AccountListSection(model: model, provider: .grok)

            Section("刷新与提醒") {
                Picker("自动刷新", selection: $model.preferences.refreshIntervalMinutes) {
                    Text("1 分钟").tag(1)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("15 分钟").tag(15)
                }
                Toggle("低额度通知", isOn: $model.preferences.notificationsEnabled)
                Picker("提醒阈值", selection: $model.preferences.notificationThreshold) {
                    Text("10%").tag(10)
                    Text("20%").tag(20)
                    Text("25%").tag(25)
                }
                Toggle("启动时显示悬浮面板", isOn: $model.preferences.floatingPanelEnabled)
            }

            Section {
                Text("QuotaPeek 只在本机调用官方 CLI/API；不会上传账号凭证或额度数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func pathField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(title).frame(width: 62, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
```

- [ ] **Step 3: 编译确认通过**

Run: `swift build`
Expected: 编译成功。

- [ ] **Step 4: 全量测试确认零回归**

Run: `swift test`
Expected: 全部 PASS。

- [ ] **Step 5: 手工走查**

```bash
pkill -f "dist/QuotaPeek.app/Contents/MacOS/QuotaPeek" 2>/dev/null; sleep 1
./scripts/build-app.sh && open dist/QuotaPeek.app
```

打开设置页，逐个 Provider 区块确认：
- 已迁移的默认账号显示正常，标签是"默认"，能改名、能启用/禁用。
- 给 Claude 点"+ 添加账号"，起名，确认 Terminal 被拉起、命令里带对了新目录路径。
- 给 GLM/Grok 点"+ 添加账号"，粘贴一个假 Key/Cookie，确认能保存、状态文案会更新。
- 删除一个刚加的测试账号，确认它从列表和面板卡片里都消失。

- [ ] **Step 6: Commit**

```bash
git add Sources/QuotaPeek/UI/AccountListSection.swift Sources/QuotaPeek/UI/SettingsView.swift
git commit -m "feat: 设置页改为账号列表 UI，支持增删改多账号"
```

---

### Task 12: 清理 `AppPreferences` 遗留字段

**Files:**
- Modify: `Sources/QuotaPeek/Domain/Preferences.swift`

**Interfaces:**
- Consumes: 无（此时 `SettingsView`/`ProviderFactory`/`AppModel` 都已经不读 `codexEnabled` 等旧字段——Task 9/11 已经把它们全部换成 `preferences.accounts`）。
- Produces: 无新接口，纯删除。

**背景**：Task 4 出于"保持每个任务边界都能编译"的考虑，暂时保留了 `codexEnabled`/`claudeEnabled`/`kimiEnabled`/`glmEnabled`/`grokEnabled`/`glmBaseURL` 六个字段，只是不再被任何代码路径读取。现在可以安全删掉了。

- [ ] **Step 1: 用 grep 确认真的没人在读旧字段**

Run: `grep -rn "\.codexEnabled\|\.claudeEnabled\|\.kimiEnabled\|\.glmEnabled\|\.grokEnabled\|\.glmBaseURL" Sources/`
Expected: 只有 `Preferences.swift` 自己（`LegacyCodingKeys`/`migrateLegacyAccounts` 内部用字符串 key，不是属性访问，grep 不会命中）。如果 grep 到别处还有引用，先处理掉那处再继续。

- [ ] **Step 2: 删掉 `migrateLegacyAccounts` 之外没用的东西**

`migrateLegacyAccounts(from:)` 本身**不删**（旧版缓存的 `UserDefaults` JSON blob 仍然是老结构，删了这段函数下次启动就没法迁移了，导致老用户账号凭证"丢失"）。这一步只是确认没有多余的、读旧字段的**属性**残留在 `AppPreferences` 主体里——检查一遍当前文件（Task 4 写的版本）应该已经是干净的：`accounts` / `codexExecutable` / `claudeExecutable` / `kimiExecutable` / `refreshIntervalMinutes` / `notificationThreshold` / `notificationsEnabled` / `floatingPanelEnabled`，没有多余字段。如果发现有，删掉。

- [ ] **Step 3: 回归测试确认迁移逻辑依然完整**

Run: `swift test --filter PreferencesMigrationTests`
Expected: Task 4 写的 3 个测试依然 PASS——这是回归验证，确认"清理"这一步没有误删迁移逻辑本身。

- [ ] **Step 4: 全量测试 + 编译**

Run: `swift build && swift test`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/QuotaPeek/Domain/Preferences.swift
git commit -m "chore: 确认 AppPreferences 旧字段清理完毕"
```

（如果 Step 1/2 没有发现任何需要删除的代码，这个任务就是一次确认性的空提交检查——正常，说明 Task 4 当初已经写得足够干净；这种情况下可以跳过 commit。）

---

### Task 13: 最终集成验证 + README

**Files:**
- Modify: `README.md`

**Interfaces:**
- 无新接口，纯验收 + 文档。

- [ ] **Step 1: 全量测试**

Run: `swift test`
Expected: 全部 PASS（累计新增：`ProviderAccountTests` 4、`ProviderSnapshotIdentityTests` 3、`RecommendationTests` 4、`PreferencesMigrationTests` 3、`ProbeEnvironmentTests` 4、`TerminalLauncherTests` 3、`ProviderFactoryTests` 3、`AccountKeychainMigrationTests` 3，共 27 个新测试，原有测试全部照旧 PASS）。

- [ ] **Step 2: Release 构建 + 重装验证**

```bash
pkill -f "dist/QuotaPeek.app/Contents/MacOS/QuotaPeek" 2>/dev/null; sleep 1
./scripts/build-app.sh && open dist/QuotaPeek.app
```

- [ ] **Step 3: 端到端手工验收清单**

逐条确认（这些是设计文档"背景与目标"里承诺的行为，必须全部走一遍）：

- [ ] 升级前有配置的 Provider，升级后不用重新登录，卡片正常出数据。
- [ ] 给 Claude 新增第二个账号（真实登录一个小号，或至少走完 Terminal 拉起流程），面板出现"Claude · <label1>"和"Claude · <label2>"两张卡片。
- [ ] 单账号 Provider 的卡片标题没有账号后缀（视觉和改动前一致）。
- [ ] 推荐排序（最上面那张卡片）在多账号场景下选的是分数最高的账号，不是固定第一个。
- [ ] 删除一个账号后，面板卡片和设置页列表都同步消失，且不影响同 Provider 下其它账号继续正常刷新。
- [ ] GLM/Grok 新增第二个账号、分别粘贴不同的 Key/Cookie，两张卡片各自独立出数据。
- [ ] Kimi 账号能从 CLI 模式"追加网页登录"升级成网页接口，另一个 Kimi 账号不受影响。
- [ ] 低额度通知在两个同 Provider 账号各自独立触发，不会互相吞掉。

- [ ] **Step 4: 更新 README**

在 `README.md` "功能"小节（`- **智能推荐**：...` 那条附近）追加一条：

```markdown
- **多账号**：同一个 Provider 可以添加多个账号（比如公司 + 个人两个 Claude 订阅），各自独立刷新、独立参与排序和提醒；账号凭证按账号分别存储，互不影响。
```

在"配置"小节末尾（`如果 GLM 凭证已配置在 ...` 那句之后）追加一段：

```markdown
### 多账号

在设置页每个 Provider 区块点"+ 添加账号"：CLI 类（Codex/Claude/Kimi）会新建一个隔离的登录目录并拉起 Terminal，像平时一样登录一次即可；GLM/Grok 类直接填一份新的 Key/Cookie。账号名自己起，方便区分（如"工作"/"个人"）。删除账号会清掉它本地保存的登录信息，需要重新添加才能再用。
```

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: README 补充多账号支持说明"
```

---

## Self-Review 记录

- **Spec 覆盖检查**：设计文档的 8 个组件设计小节（Keychain 分 key / KimiWebSession / ProviderFactory / 探针 homeDirectory / AppModel / TerminalLauncher / SettingsView / DashboardViews）分别对应 Task 5、5、8、6、9+10、7、11、9，"迁移策略"对应 Task 4，"测试"小节列的每一类测试都能在对应任务里找到（Codable 往返→Task1，迁移测试→Task4，推荐算法→Task3）。"非目标"部分（不做导入已有目录、不自动探测标签、不做排序自定义等）本计划没有任何任务实现它们，符合预期。
- **占位符检查**：全文没有 TBD/TODO；Task 9 里的 `secretOverride`/`kimiWebSession(for:)` 占位实现在 Task 10 立刻被替换掉，且写清楚了替换点在哪一步，不是永久占位。
- **类型一致性检查**：`ProviderAccount`/`AccountCredential`（Task 1）→`ProviderSnapshot.accountID`（Task 2）→`Recommendation`（Task 3）→`AppPreferences.accounts`（Task 4）→`KimiWebSession`（Task 5）→探针 `homeDirectory`（Task 6）→`TerminalLauncher`（Task 7）→`ProviderFactory.make(accounts:...)`（Task 8）→`AppModel`（Task 9/10）→`AccountListSection`（Task 11），每一层引用上一层产出的确切签名，没有出现名字不一致的情况（比如统一用 `recommendedAccountID`，没有一个任务写成 `recommendedAccountId` 或 `preferredAccountID`）。

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-25-multi-account-support.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
