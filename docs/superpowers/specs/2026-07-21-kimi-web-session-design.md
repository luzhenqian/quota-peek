# Kimi 网页会话直连会员额度 — 设计文档

日期：2026-07-21
状态：已批准，待实现

## 背景与目标

QuotaPeek 的 Kimi 卡片当前通过 `kimi /usage`（CLI）获取额度，只能拿到**每周**和**5 小时**两档，缺两项数据：

- **套餐名**（如 Allegro）
- **月度总额度**（Kimi 对话 + Kimi Code 合并计算的月度用量）

这两项数据 CLI 完全不暴露——反编译 Kimi CLI 二进制确认其中没有任何拉取套餐名/月度额度的接口调用。它们只存在于网页面板 `www.kimi.com` 背后的会员接口。

### 已验证的接口（实测抓取）

宿主：`https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/`
调用方式：Connect-RPC over HTTP，`POST` + JSON body `{}`，头 `Authorization: Bearer <access_token>`。

**`GetSubscriptionStats`** 返回：
```json
{
  "ratelimitCode5h": { "enabled": true, "resetTime": "2026-07-21T03:15:20Z" },
  "ratelimitCode7d": { "ratio": 0.2281, "enabled": true, "resetTime": "2026-07-25T00:15:20Z" },
  "subscriptionBalance": {
    "feature": "FEATURE_OMNI",
    "unit": "UNIT_CREDIT",
    "amountUsedRatio": 0.5061,
    "kimiCodeUsedRatio": 0.0478,
    "expireTime": "2026-08-18T00:00:00Z"
  }
}
```

**`GetSubscription`** 返回（截断）：
```json
{ "subscription": { "goods": {
    "title": "Allegro",
    "membershipLevel": "LEVEL_ADVANCED",
    "durationDays": 30
  },
  "currentEndTime": "2026-08-18T00:00:00Z",
  "nextBillingTime": "2026-08-17T00:15:21Z",
  "status": "SUBSCRIPTION_STATUS_ACTIVE"
}}
```

字段映射：
- `subscriptionBalance.amountUsedRatio` = 月度总用量比例（0.5061 → 剩 49.39%），`expireTime` = 月度重置。
- `ratelimitCode7d.ratio` = 每周用量（0.2281 → 剩 77.19%），`resetTime` = 每周重置。
- `ratelimitCode5h` = 5 小时窗口；当前用量为 0 时**无 `ratio` 字段**，按 0 用量处理（剩 100%），`resetTime` = 重置时间。
- `subscription.goods.title` = 套餐名（"Allegro"）。

这些数字与 CLI 的 weekly 23%/5h 0% 完全一致，说明 `GetSubscriptionStats` 一次即可替代整个 CLI 解析，且多出月度那条。

### 鉴权与刷新（实测）

- 网页 token 为 JWT，发行方 `user-center`，`app_id: kimi`；**access 有效期 30 天、refresh 90 天**。
- token 存放在网页 `localStorage` 的 `access_token` / `refresh_token`（与 CLI 的 `~/.kimi/credentials/kimi-code.json` 是两套独立凭证，互不干扰）。
- token 刷新端点在压缩混淆的前端代码中动态拼接，无法静态提取；网页 app 在后台自行刷新。
- 登录方式：短信验证码 / 微信 / Google——均为浏览器交互流程。

## 架构决策

因为登录全是浏览器交互、且刷新协议未公开，**不在原生层复刻 OAuth 登录与刷新**（脆弱且工作量巨大）。改为内嵌一个 **WKWebView 持久会话**：用户首次在 WebView 里正常登录一次，之后 WebView 持久保存会话（cookie + localStorage 落地磁盘），**token 刷新完全交给 Kimi 自己的网页 JS**。QuotaPeek 只需在这个已登录、同源的 WebView 里执行会员接口的 fetch。

这样把"登录 + 自动刷新"这两件最脏、最易变的事甩给 Kimi 网页逻辑自身，原生侧不碰任何私有协议，鲁棒性远高于手写实现。90 天内无需重新登录。

## 组件设计

### 1. `KimiWebSession`（新，`Sources/QuotaPeek/Infrastructure/KimiWebSession.swift`）

`@MainActor` 单例（WKWebView 仅限主线程）。持有一个常驻的隐藏 `WKWebView`，使用持久化 `WKWebsiteDataStore`（`.default()`，落地磁盘）。

对外接口：
- `var isLoggedIn: Bool { get async }` — 在 WebView 里读 `localStorage.access_token` 是否存在，并解码其 `exp` 判断 refresh 是否未过期。
- `func presentLogin() async` — 弹出一个 `NSWindow`，内嵌 WebView 导航到 kimi.com 登录页；轮询 `localStorage.access_token` 出现即判定登录成功、关窗，并置持久标志 `kimiWebLoggedIn = true`。
- `func fetchMembership() async throws -> (stats: Data, subscription: Data)` — 确保 WebView 已加载 `www.kimi.com`（同源），执行 JS 依次 POST `GetSubscriptionStats`、`GetSubscription`（带 localStorage 的 `access_token` 作 Bearer），返回两段原始 JSON。
- `func logout() async` — 清 WebView 的 `WKWebsiteDataStore` 数据，置 `kimiWebLoggedIn = false`。

内部：为保证同源 fetch 可用，常驻 WebView 持续停在 `www.kimi.com`；Kimi 网页 app 会自动刷新 token。

### 2. `KimiMembershipParser`（新，纯函数，置于 `Sources/QuotaPeek/Providers/KimiWebProbe.swift` 内）

签名：`static func parse(stats: Data, subscription: Data, capturedAt: Date = Date()) throws -> ProviderSnapshot`

- 解析 JSON，产出 3 个 `QuotaWindow`，`kind` 分别为 `.monthly`、`.weekly`、`.session`。
  - `QuotaWindowKind` 已有 `.monthly`（displayName "每月"）、`.weekly`、`.session`，直接复用，不新增枚举。
- `remainingPercent = (1 - usedRatio) * 100`。5h 无 `ratio` 时 usedRatio = 0。
- `resetsAt` 从 ISO8601 字符串解析（用 `ISO8601DateFormatter`，注意纳秒精度 `resetTime` 带小数秒，需容错）。
- `plan = subscription.goods.title`（保留原样 "Allegro"，不 uppercase）。
- 纯函数，可用抓取的真实 JSON 字节单测。

### 3. `KimiWebProbe`（新，`Sources/QuotaPeek/Providers/KimiWebProbe.swift`）

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

`fetchMembership` 内部处理 401：重载页面一次触发网页刷新 → 重试；仍 401 则抛 `authenticationRequired` 并翻掉 `kimiWebLoggedIn` 标志。

### 改动 1：`Package.swift`

`QuotaPeek` target 的 `linkerSettings` 增加 `.linkedFramework("WebKit")`。

### 改动 2：`ProviderFactory`

Kimi 路由由持久标志 `kimiWebLoggedIn`（存 UserDefaults / AppPreferences）决定：

```swift
if preferences.kimiEnabled {
    if preferences.kimiWebLoggedIn {
        probes.append(KimiWebProbe())          // source .officialAPI
    } else {
        probes.append(KimiProbe(...))          // 现有 CLI，source .cli
    }
}
```

未登录用户行为完全不变；登录即升级为网页接口。标志位是提示——若 session 实际已过期，`KimiWebProbe` 会失败并翻掉标志、本次回退 CLI。

### 改动 3：`AppPreferences`

新增 `var kimiWebLoggedIn = false`。（复用现有 `PreferencesStore` 的 UserDefaults 持久化。）

### 改动 4：`SettingsView`

Kimi 分区新增：
- "登录 Kimi 网页账号" 按钮 → `KimiWebSession.shared.presentLogin()`
- 状态文案："已登录（网页接口）" / "未登录（使用 CLI）"
- "退出登录" 按钮 → `logout()`

## 数据流

刷新循环 → `KimiWebProbe.fetch()` → `KimiWebSession.fetchMembership()`（常驻 WebView 内执行 fetch，同源、自动带 token）→ 两段 JSON → `KimiMembershipParser` → `ProviderSnapshot`（窗口：每月 / 每周 / 5 小时；plan："Allegro"）→ 卡片渲染。

## 错误处理

- **fetch 返回 401**（session 真过期）：重载页面一次 → 重试；仍失败则翻掉 `kimiWebLoggedIn`、本次回退 CLI、设置页提示"请重新登录"。上一份好数据由现有 `SnapshotStore` 缓存保留。
- **WebView 加载失败 / fetch 超时**：抛 `timedOut`。
- **未登录**：`kimiWebLoggedIn = false`，工厂直接用 CLI 探针，无回归。

## 测试

- `KimiMembershipParser` 单测（`Tests/QuotaPeekTests/ProviderParserTests.swift` 新增用例）：用本文档"已验证的接口"中的真实 JSON 字节，断言：
  - 3 个窗口，`kind` 分别为 `.monthly` / `.weekly` / `.session`
  - `remainingPercent`：每月 49.39、每周 77.19、5 小时 100
  - `plan == "Allegro"`
  - `resetsAt` 非空且 ISO8601 解析正确（含带小数秒的时间戳）
- WKWebView / `KimiWebSession` 保持薄，靠打包后跑真机验证登录与刷新。

## 非目标（YAGNI）

- 不显示 `kimiCodeUsedRatio`（月度中 Code 占比）——只展示月度总量，保持卡片简洁。
- 不做原生短信/微信/Google 登录。
- 不复刻 token 刷新协议。
