# 多账号支持 — 设计文档

日期：2026-07-25
状态：待用户确认

## 背景与目标

QuotaPeek 目前假设每个 Provider 只有一个账号：`ProviderID`（codex/claude/kimi/glm/grok）既是"服务商类型"，也是"数据身份"——`ProviderSnapshot.id` 直接等于 `ProviderID`，偏好设置里每个 Provider 只有一组 `xxxEnabled` / `xxxExecutable` 字段，Keychain 里 GLM/Grok 的凭证也用固定字符串做 key。

用户可能同时持有多个同一 Provider 的订阅（如公司 Claude Max + 个人 Claude Pro，或两个 Codex 账号），需要在同一块面板里分别看到每个账号的额度、分别参与"优先推荐"排序。范围确认为：**Codex、Claude、Kimi（CLI + 网页两种模式）、GLM、Grok 全部支持多账号**。

### 可行性确认（已验证）

反查本机安装的三个 CLI 二进制字符串，确认都支持通过环境变量重定向登录/配置目录，天然适合"一个目录 = 一个隔离账号"：

| CLI | 环境变量 | 默认值 |
| --- | --- | --- |
| Claude Code | `CLAUDE_CONFIG_DIR` | `~/.claude` |
| Codex | `CODEX_HOME` | `~/.codex` |
| Kimi Code | `KIMI_CODE_HOME` | `~/.kimi-code` |

Codex CLI 和 Kimi CLI 都有显式 `login` 子命令；Claude Code 没有独立 `login` 子命令，直接运行 `claude` 在未登录时会自动走它自己的 OAuth 登录流程。GLM（API Key）、Grok（Cookie）、Kimi 网页（`WKWebsiteDataStore(forIdentifier:)`，macOS 14+ 原生支持隔离持久 cookie 存储）三种凭证类型天生就是"一份凭证一个字符串/一个 store"，多账号只是换个 key 的问题，没有可行性风险。

## 架构决策

引入统一的 `ProviderAccount`（账号）作为新的身份单元，`ProviderID` 退化为纯粹的"服务商类型标签"（决定图标、配色、走哪个 probe 实现），不再是身份键。`ProviderSnapshot` 按账号（UUID）而非 Provider 类型建索引。

对"新增账号"这件事，CLI 类账号的登录动作**交给用户在系统 Terminal 里完成**——App 只负责建隔离目录、拉起 Terminal 跑登录命令，不在内部自动化 OAuth 交互（这类交互本来就因 CLI 而异、且大多涉及浏览器跳转，硬编码自动化脆弱且维护成本高，与本项目 Kimi 网页会话那次"不复刻登录协议"的判断一致）。登录完成与否也不单独做状态机——沿用现有"未登录 = fetch 失败 = 卡片显示错误"这条路径，下一轮自动刷新自然会验证到位。

迁移策略：给每个 Provider 一个**固定**（非随机）的"迁移专用账号 UUID"，把旧版单账号配置无损转换成一个 label 为"默认"的账号，CLI 路径留空（=沿用 CLI 自己的默认目录，不用重新登录）、Keychain/网页会话凭证原样搬到新 key。固定 UUID 保证这个迁移在多次启动之间是幂等的。

## 数据模型

新建 `Sources/QuotaPeek/Domain/ProviderAccount.swift`：

```swift
struct ProviderAccount: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var provider: ProviderID
    var label: String          // 用户手动起的名字，如"工作"；迁移账号固定为"默认"
    var credential: AccountCredential
    var enabled: Bool = true
}

enum AccountCredential: Codable, Equatable, Sendable {
    case cliHome(path: String)     // Claude / Codex：CLI 配置目录路径，空串 = 用 CLI 自己的默认目录
    case kimi(cliHomePath: String) // Kimi：同上的 CLI 目录；是否叠加网页登录用下面的 per-account 标志位判断，
                                    // 不在这里存 WKWebsiteDataStore 标识符——它由 account.id 派生（见下）
    case apiKey(baseURL: String)   // GLM：密钥本身存 Keychain，这里只留 base URL
    case cookie                    // Grok：密钥本身存 Keychain
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
}
```

`ProviderSnapshot`（`Domain/Models.swift`）新增 `accountID: UUID`，`id` 改为返回它；已有的 `account: String?` 字段（此前从未被赋值）复用为账号标签展示用途：

```swift
var id: UUID { accountID }
var accountID: UUID
...
var account: String?   // 账号标签（如"工作"）；单账号 provider 上为 nil，UI 据此决定要不要显示后缀
```

`failure(...)` 静态构造方法加 `accountID` / `label` 两个参数。

`AppPreferences`（`Domain/Preferences.swift`）：删除 `xxxEnabled` / `xxxExecutable` / `glmBaseURL` 五组字段，替换为 `var accounts: [ProviderAccount] = []`。`init(from:)` 增加一次性迁移：解出的容器里如果没有 `accounts` 键，就用一份 `LegacyCodingKeys`（列出旧字段名）解出旧值，为每个"曾经启用或填过路径/曾经登录"的 Provider 合成一条 `ProviderAccount(id: .legacyDefaultID(for:), label: "默认", ...)`。

## 组件设计

### 1. Keychain / 网页会话按账号 UUID 重新分 key

- `SecretStore`（`Infrastructure/SecretStore.swift`）接口不变（本来就接受任意 `account: String`）。调用方从固定字符串 `"glm-api-key"` / `"grok-cookie"` 改成 `"glm-api-key-\(account.id.uuidString)"` / `"grok-cookie-\(account.id.uuidString)"`。
- `AppModel` 启动时做一次幂等 Keychain 搬迁：若旧固定 key 有值且新 key（用 `legacyDefaultID`拼出）还没有值，读旧写新（不删旧，留作回滚余地）。用 `UserDefaults` 标志 `QuotaPeek.migratedAccountKeychain.v1` 防重复搬迁。

### 2. `KimiWebSession`（改为按账号持有，去掉全局单例）

去掉 `static let shared`；`websiteDataStore` 从硬编码 `.default()` 改成初始化参数：

```swift
init(dataStore: WKWebsiteDataStore) { ... }
```

`AppModel` 维护 `[UUID: KimiWebSession]`，首次用到某账号时惰性创建：迁移来的默认 Kimi 账号用 `.default()`（保留已有登录，不用重新登录）；其余账号用 `WKWebsiteDataStore(forIdentifier: account.id)`。登录状态标志从单一 `QuotaPeek.kimiWebLoggedIn` 改成按账号 `QuotaPeek.kimiWebLoggedIn.\(account.id)`。`presentLogin()` / `logout()` 内部逻辑不变，只是不再操作全局单例的 `.default()`，而是操作自己持有的 `dataStore`。

### 3. `ProviderFactory`

从"5 个固定 Provider 各建一个 probe"改成"遍历 `accounts` 里 enabled 的账号，各建一个 probe"：

```swift
static func make(
    accounts: [ProviderAccount],
    secret: (ProviderAccount) -> String?,   // GLM key / Grok cookie，调用方按 account.id 查 Keychain
    kimiWebSession: (ProviderAccount) -> KimiWebSession
) -> [(account: ProviderAccount, probe: any ProviderProbe)]
```

Kimi 账号路由逻辑和今天完全一样，只是判断对象从全局 `KimiWebSession.isLoggedIn` 变成"这个账号是否登录过网页"：登录过用 `KimiWebProbe`，没登录过用 `KimiProbe(homeDirectory:)`。

### 4. `ClaudeProbe` / `CodexProbe` / `KimiProbe` 加 `homeDirectory` 参数

三者构造函数各加一个 `homeDirectory: String`（空串 = 不设环境变量，用 CLI 默认目录），内部拼进已有的 `environment:` 字典传给 `ProcessRunner`：

```swift
// ClaudeProbe.fetch() 内，原有 environment 字典基础上加一行：
environment: [
    "ANTHROPIC_API_KEY": "", "ANTHROPIC_AUTH_TOKEN": "", "ANTHROPIC_BASE_URL": "",
    "CLAUDE_CONFIG_DIR": homeDirectory   // 空串时相当于不设置（Process 环境变量为空值，CLI 视为未设置）
]
```

`ProcessRunner` / `ProviderProbe` 协议本身不用改。`GLMProbe` / `GrokProbe` 构造参数不变（`apiKey` / `cookie` 仍是外部传入的字符串），probe 本身不感知账号概念。

### 5. `AppModel`

- `refreshAll()`：`ProviderFactory.make(accounts: preferences.accounts.filter(\.enabled), ...)` 拿到 `(account, probe)` 列表；fetch 成功后把结果的 `accountID` / `account`(label) 补上再存入 `snapshots`。
- CLI 探针分组：现状是"所有 `.cli` 来源的 probe 挤在一个任务里顺序跑"（避免同一登录目录内并发探测撞车），多账号后如果继续把**所有账号**都塞进一条顺序队列，账号一多刷新时间会线性增长。改成先照旧按 `probe.source == .cli` 筛出 CLI 探针，再在这个子集内部按 `(provider, homeDirectory)` 分组——同一账号目录内的重试仍然顺序进行（沿用现有 `fetchCLIResult` 失败重试一次的逻辑），不同账号（哪怕同一 Provider）因为目录互相隔离、天然无共享状态，分到不同分组并发跑；非 CLI 来源（GLM/Grok/Kimi 网页）不受影响，照常并发。
- `visibleSnapshots` / `overallRemainingPercent` / `menuBarSymbol`：内部逻辑本来就是泛化在 `[ProviderSnapshot]` 上操作，无需大改，只是列表元素从"5 个固定 Provider"变成"N 个账号"。
- 推荐算法目前是 `AppModel` 里的 `private static func`，只能通过 `@MainActor` 单例间接测——顺手挪成独立纯函数模块 `Domain/Recommendation.swift`（`headlineWindow` 已经是 `ProviderSnapshot` 的计算属性，不用动；新增 `recommendedAccountID(among:now:) -> UUID?` 和 `recommendationScore(for:now:) -> Double?`），`AppModel.recommendedAccountID` 变成薄封装，方便直接单测。
- 新增账号管理方法：`addCLIAccount(provider:label:)`（建目录、拉起 Terminal）、`addCredentialAccount(provider:label:)`（GLM/Grok，建空账号等用户去填 Key/Cookie）、`addKimiWebAccount(label:)`、`removeAccount(id:)`、`renameAccount(id:label:)`。

### 6. 拉起 Terminal 登录

新建 `Infrastructure/TerminalLauncher.swift`：

```swift
enum TerminalLauncher {
    static func run(command: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "\(command.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        // 通过 osascript 执行；失败静默——用户可以自己开 Terminal 手动敲命令
    }
}
```

各 Provider 拼出的命令：

| Provider | 命令 |
| --- | --- |
| Claude | `CLAUDE_CONFIG_DIR="<dir>" claude` |
| Codex | `CODEX_HOME="<dir>" codex login` |
| Kimi CLI | `KIMI_CODE_HOME="<dir>" kimi login` |

App 不追踪登录是否完成——账号先以"待验证"状态加入列表，下一轮自动刷新 fetch 成功即转正常，失败则走现有"需要登录"错误卡片，用户可以随时回来手动点一次刷新重试。

### 7. `SettingsView` 重构

新建可复用组件 `UI/AccountListSection.swift`，按 Provider 渲染一组账号：每行显示 label（可编辑文本框）、启用开关、状态（正常/需要登录/凭证未配置，取当前 snapshot 的 `errorMessage` 判断）、删除按钮；区块底部一个"+ 添加账号"入口，按 Provider 类型弹出对应的添加流程（CLI 类起名后直接建目录+拉 Terminal；Grok 类起名后接一个 Cookie 输入框；GLM 类起名后接 Base URL + API Key 两个输入框，对齐现状的两个字段；Kimi 额外提供"追加网页登录"动作，让同一 CLI 账号升级成网页模式，行为对齐现状）。

原 `SettingsView.swift` 里 5 个 `Section` 全部替换为 5 个 `AccountListSection` 调用；"刷新与提醒"等全局设置区块不变。

### 8. `DashboardViews.swift`

- `ProviderCards`：按 `Dictionary(grouping: model.visibleSnapshots, by: \.provider).mapValues(\.count)` 算出每个 Provider 当前可见账号数，传给 `ProviderCard` 一个 `showsAccountLabel: Bool`（>1 才 true）。
- `ProviderCard` 标题：`provider.displayName`，`showsAccountLabel && let label = snapshot.account` 时追加 `" · \(label)"`。单账号 Provider 视觉上和现在完全一样。
- `isRecommended` 判断从 `snapshot.provider == model.recommendedProvider` 改成 `snapshot.accountID == model.recommendedAccountID`。

## 数据流（新增账号，以 Claude 为例）

设置页点"+ 添加账号" → 起名"工作" → `AppModel.addCLIAccount(.claude, label: "工作")` 建目录 `~/Library/Application Support/QuotaPeek/Accounts/<uuid>/`、生成 `ProviderAccount` 并存入 `preferences.accounts` → `TerminalLauncher.run("CLAUDE_CONFIG_DIR=\"<dir>\" claude")` 拉起 Terminal，用户在其中正常登录 → 下一轮 `refreshAll()` 里 `ClaudeProbe(homeDirectory: <dir>).fetch()` 读到刚登录的凭证、成功返回 → 面板出现"Claude · 工作"新卡片，参与统一的排序/推荐/通知。

## 错误处理

- 新账号还没登录完成时 fetch 失败：走现有 `ProviderSnapshot.failure` 路径，卡片显示错误信息，不影响其它账号的并发刷新。
- 删除账号：CLI 类删目录（`FileManager.removeItem`，失败忽略）；Keychain 类清对应 key；Kimi 网页类调 `WKWebsiteDataStore.remove(forIdentifier:)`；最后从 `preferences.accounts` 移除该条。删除是纯配置操作，不需要中断正在进行的刷新。
- Keychain 迁移失败（钥匙串访问被拒绝等）：记录一次，不阻塞启动；旧固定 key 保留，用户可以在新账号行里手动重新粘贴一次凭证。
- `SnapshotStore` 本地缓存：旧版缓存 JSON 里的 `ProviderSnapshot` 没有 `accountID` 字段，解码会整体失败——现有 `load()` 已经用 `try?` 兜底成空数组，属于可接受的一次性冷启动（首次刷新完成后正常重新写入），不需要额外的兼容代码。

## 测试

- `ProviderAccount` / `AccountCredential` 的 Codable 往返测试。
- `AppPreferences` 迁移测试：构造一份只含旧字段（`codexEnabled` / `claudeExecutable` / `glmBaseURL` 等，无 `accounts` 键）的 JSON，decode 后断言生成的账号数、`id` 命中各自的 `legacyDefaultID`、`label == "默认"`、`enabled` 与旧布尔值一致；再构造一份已含 `accounts` 数组的新版 JSON，断言不会重复触发迁移。
- `Recommendation.recommendedAccountID` 单测：构造同一 Provider 两个账号的 `ProviderSnapshot`（不同剩余量/刷新时间组合），断言选中的 accountID 符合"剩余% × 紧迫度"打分。
- 现有 `ProviderParserTests` 不受影响（probe 的 parse 纯函数不感知账号概念）。
- Terminal 拉起 / 实际 CLI 登录 / WKWebView 多 data store 隔离，跟此前 Kimi 网页会话一样，走真机手工验证，不纳入自动化测试范围。

## 非目标（YAGNI）

- 不做"扫描并导入用户已有的多个 CLI 登录目录"——本次只支持通过 App 内"添加账号"新建隔离目录，不支持指定任意已存在路径。
- 不自动探测邮箱/套餐名作为默认账号标签——已确认手动起名。
- 不支持账号排序自定义（拖拽调整顺序）、不支持导入导出账号配置。
- 通知阈值（`notificationThreshold`）仍是全局统一设置，不做逐账号定制。
- 不做"添加账号"时的登录完成检测/等待动画——复用现有失败态和下一轮自动刷新。
