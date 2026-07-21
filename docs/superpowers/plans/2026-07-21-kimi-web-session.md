# Kimi 网页会话直连会员额度 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 QuotaPeek 的 Kimi 卡片在用户登录 Kimi 网页账号后显示套餐名（如 Allegro）与月度总额度，通过内嵌 WKWebView 持久会话直连会员接口。

**Architecture:** 一个 `@MainActor` 的 `KimiWebSession` 单例持有常驻隐藏 WKWebView（持久化 data store，token 刷新交给 Kimi 网页 JS）；纯函数 `KimiMembershipParser` 把会员接口 JSON 解析成 `ProviderSnapshot`；`KimiWebProbe` 把两者串起来。`ProviderFactory` 按持久标志 `kimiWebLoggedIn` 在网页探针与现有 CLI 探针间路由。

**Tech Stack:** Swift 6.2, AppKit + SwiftUI, WebKit（WKWebView），XCTest。

## Global Constraints

- 平台：macOS 14+，Swift 6.2（`Package.swift` 现有 `swift-tools-version: 6.2`）。
- WKWebView 仅限主线程 —— `KimiWebSession` 全部标 `@MainActor`。
- 不新增第三方依赖；不复刻 Kimi 的 OAuth/刷新协议。
- 界面文案用简体中文，与现有 UI 一致。
- 未登录用户行为必须与当前完全一致（回退现有 `KimiProbe` CLI 路径）。
- 复用现有类型：`ProviderSnapshot`、`QuotaWindow`、`QuotaWindowKind`（已含 `.session`/`.weekly`/`.monthly`）、`SnapshotSource.officialAPI`、`ProbeError`。
- 会员接口（实测）：`POST https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats` 与 `.../GetSubscription`，body `{}`，头 `Authorization: Bearer <localStorage.access_token>`、`content-type: application/json`。
- 项目非 git 仓库 —— 所有 “Commit” 步骤跳过，改为运行一次 `swift build` 确认编译通过。

---

## File Structure

- Create: `Sources/QuotaPeek/Providers/KimiWebProbe.swift` —— `KimiWebProbe`（探针）+ `KimiMembershipParser`（纯函数解析器），二者紧耦合、同生共死，放一个文件。
- Create: `Sources/QuotaPeek/Infrastructure/KimiWebSession.swift` —— `@MainActor` WKWebView 会话封装（登录、fetch、登出）。
- Modify: `Package.swift` —— 给 `QuotaPeek` target 加 `.linkedFramework("WebKit")`。
- Modify: `Sources/QuotaPeek/Domain/Preferences.swift` —— `AppPreferences` 加 `kimiWebLoggedIn`。
- Modify: `Sources/QuotaPeek/Providers/ProviderFactory.swift` —— Kimi 路由分支。
- Modify: `Sources/QuotaPeek/App/AppModel.swift` —— 暴露 `kimiLogin()`/`kimiLogout()`/`kimiWebLoggedIn` 给设置页。
- Modify: `Sources/QuotaPeek/UI/SettingsView.swift` —— Kimi 登录分区。
- Modify: `Tests/QuotaPeekTests/ProviderParserTests.swift` —— 新增 `KimiMembershipParser` 单测。

任务顺序：先做纯函数解析器（可 TDD、无 UI 依赖），再做 WebView 会话，再做探针与工厂路由，最后接 UI。

---

## Task 1: `KimiMembershipParser` 解析器（TDD）

**Files:**
- Create: `Sources/QuotaPeek/Providers/KimiWebProbe.swift`
- Test: `Tests/QuotaPeekTests/ProviderParserTests.swift`（在末尾 `}` 前新增用例）

**Interfaces:**
- Consumes: `ProviderSnapshot`、`QuotaWindow`、`QuotaWindowKind`、`ProbeError`（均已存在于 `Domain/Models.swift`）。
- Produces: `enum KimiMembershipParser { static func parse(stats: Data, subscription: Data, capturedAt: Date = Date()) throws -> ProviderSnapshot }`。窗口顺序：`.session`、`.weekly`、`.monthly`。`plan` 为 `subscription.goods.title` 原样字符串。

- [ ] **Step 1: 写失败测试**

在 `Tests/QuotaPeekTests/ProviderParserTests.swift` 里，`testClaudeUsageWithUsedAndLeftFormats()` 之前插入：

```swift
    func testKimiMembershipParsesWindowsAndPlan() throws {
        let stats = Data(#"""
        {"ratelimitCode5h":{"enabled":true,"resetTime":"2026-07-21T03:15:20.899140218Z"},
         "ratelimitCode7d":{"ratio":0.2281,"enabled":true,"resetTime":"2026-07-25T00:15:20.899140218Z"},
         "subscriptionBalance":{"id":"x","feature":"FEATURE_OMNI","type":"SUBSCRIPTION","unit":"UNIT_CREDIT",
           "amountUsedRatio":0.5061,"kimiCodeUsedRatio":0.0478,"expireTime":"2026-08-18T00:00:00Z"}}
        """#.utf8)
        let sub = Data(#"""
        {"subscription":{"subscriptionId":"y","goods":{"id":"z","title":"Allegro","durationDays":30,
           "membershipLevel":"LEVEL_ADVANCED"},"status":"SUBSCRIPTION_STATUS_ACTIVE","active":true}}
        """#.utf8)

        let snapshot = try KimiMembershipParser.parse(stats: stats, subscription: sub)

        XCTAssertEqual(snapshot.plan, "Allegro")
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows[0].kind, .session)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 100, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[1].kind, .weekly)
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 77.19, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[2].kind, .monthly)
        XCTAssertEqual(snapshot.windows[2].remainingPercent, 49.39, accuracy: 0.01)
        XCTAssertNotNil(snapshot.windows[1].resetsAt)   // 带小数秒的时间戳能解析
        XCTAssertNotNil(snapshot.windows[2].resetsAt)
    }

    func testKimiMembershipMissingSubscriptionThrows() throws {
        let stats = Data(#"{"subscriptionBalance":{"amountUsedRatio":0.1,"expireTime":"2026-08-18T00:00:00Z"}}"#.utf8)
        let sub = Data(#"{}"#.utf8)
        XCTAssertThrowsError(try KimiMembershipParser.parse(stats: stats, subscription: sub))
    }
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter testKimiMembershipParsesWindowsAndPlan 2>&1 | tail -5`
Expected: 编译失败，报 `cannot find 'KimiMembershipParser' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `Sources/QuotaPeek/Providers/KimiWebProbe.swift`，先只放解析器（探针在 Task 3 补）：

```swift
import Foundation

enum KimiMembershipParser {
    private struct StatsPayload: Decodable {
        struct Ratelimit: Decodable { let ratio: Double?; let resetTime: String? }
        struct Balance: Decodable { let amountUsedRatio: Double?; let expireTime: String? }
        let ratelimitCode5h: Ratelimit?
        let ratelimitCode7d: Ratelimit?
        let subscriptionBalance: Balance?
    }

    private struct SubPayload: Decodable {
        struct Subscription: Decodable {
            struct Goods: Decodable { let title: String? }
            let goods: Goods?
        }
        let subscription: Subscription?
    }

    // Kimi 的 resetTime 带纳秒小数秒（"...20.899140218Z"）。ISO8601DateFormatter
    // 不接受任意位数小数秒，先把小数秒截掉再解析。
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        return iso.date(from: trimmed)
    }

    private static func window(kind: QuotaWindowKind, usedRatio: Double?, resetRaw: String?) -> QuotaWindow {
        let used = usedRatio ?? 0
        let reset = date(resetRaw)
        return QuotaWindow(
            kind: kind,
            remainingPercent: (1 - used) * 100,
            resetsAt: reset,
            resetDescription: reset?.quotaCountdown
        )
    }

    static func parse(stats: Data, subscription: Data, capturedAt: Date = Date()) throws -> ProviderSnapshot {
        let s = try JSONDecoder().decode(StatsPayload.self, from: stats)
        let subDecoded = try? JSONDecoder().decode(SubPayload.self, from: subscription)
        guard let plan = subDecoded?.subscription?.goods?.title, !plan.isEmpty else {
            throw ProbeError.invalidResponse("Kimi 会员接口未返回套餐信息")
        }

        var windows: [QuotaWindow] = []
        windows.append(window(kind: .session, usedRatio: s.ratelimitCode5h?.ratio,
                              resetRaw: s.ratelimitCode5h?.resetTime))
        windows.append(window(kind: .weekly, usedRatio: s.ratelimitCode7d?.ratio,
                              resetRaw: s.ratelimitCode7d?.resetTime))
        if let bal = s.subscriptionBalance {
            windows.append(window(kind: .monthly, usedRatio: bal.amountUsedRatio,
                                  resetRaw: bal.expireTime))
        }

        return ProviderSnapshot(
            provider: .kimi,
            windows: windows,
            balance: nil,
            plan: plan,
            account: nil,
            source: .officialAPI,
            capturedAt: capturedAt,
            errorMessage: nil
        )
    }
}
```

注：`Date.quotaCountdown` 是现有扩展（`Domain/Parsing.swift` / `Models.swift` 里 Codex/Kimi 探针已用）。`ProviderSnapshot` 的字段顺序与现有探针（如 `KimiProbe`）一致，若编译器报参数不匹配，照 `KimiProbe.swift` 里的构造调用对齐。

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter KimiMembership 2>&1 | grep -E "Executed|error:" | head`
Expected: 两个用例 `Executed ... 0 failures`。

- [ ] **Step 5: 验证整体编译**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`（非 git 仓库，跳过提交）。

---

## Task 2: `KimiWebSession` WKWebView 会话

**Files:**
- Create: `Sources/QuotaPeek/Infrastructure/KimiWebSession.swift`
- Modify: `Package.swift`（`QuotaPeek` target 的 `linkerSettings`）

**Interfaces:**
- Consumes: `ProbeError`。
- Produces: `@MainActor final class KimiWebSession`，单例 `static let shared`。方法：
  - `func isLoggedIn() async -> Bool`
  - `func presentLogin() async`
  - `func fetchMembership() async throws -> (stats: Data, subscription: Data)`
  - `func logout() async`
  会话状态写进 `UserDefaults`（key `QuotaPeek.kimiWebLoggedIn`），供 `ProviderFactory` 同步读取（Task 4）。

- [ ] **Step 1: 加 WebKit 链接**

修改 `Package.swift`，把 `QuotaPeek` target 的 linkerSettings 从：

```swift
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications")
            ]
```

改为：

```swift
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("WebKit")
            ]
```

- [ ] **Step 2: 创建 `KimiWebSession.swift`**

创建 `Sources/QuotaPeek/Infrastructure/KimiWebSession.swift`：

```swift
import AppKit
import WebKit

@MainActor
final class KimiWebSession: NSObject {
    static let shared = KimiWebSession()

    static let loggedInDefaultsKey = "QuotaPeek.kimiWebLoggedIn"
    private let membershipHome = URL(string: "https://www.kimi.com/membership/subscription")!

    // 常驻 WebView：持久 data store，让 cookie + localStorage 落地磁盘，
    // token 刷新交给 Kimi 网页 JS。
    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // 持久化
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        return wv
    }()

    private var loginWindow: NSWindow?

    private override init() { super.init() }

    /// 确保常驻 WebView 已停在 www.kimi.com（同源，才能带 token 直连接口）。
    private func ensureLoaded() async {
        if webView.url?.host == "www.kimi.com" { return }
        await load(membershipHome, in: webView)
    }

    private func load(_ url: URL, in wv: WKWebView) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let delegate = LoadDelegate { cont.resume() }
            self.retainedDelegate = delegate
            wv.navigationDelegate = delegate
            wv.load(URLRequest(url: url))
        }
    }
    private var retainedDelegate: LoadDelegate?

    private func readAccessToken(in wv: WKWebView) async -> String? {
        let js = "localStorage.getItem('access_token')"
        let value = try? await wv.evaluateJavaScript(js)
        return value as? String
    }

    func isLoggedIn() async -> Bool {
        await ensureLoaded()
        return await readAccessToken(in: webView)?.isEmpty == false
    }

    /// 一次拿回 GetSubscriptionStats + GetSubscription 原始 JSON。
    /// 401 时重载页面触发网页刷新，重试一次；仍失败抛错并标记未登录。
    func fetchMembership() async throws -> (stats: Data, subscription: Data) {
        await ensureLoaded()
        do {
            return try await callBoth()
        } catch ProbeError.authenticationRequired {
            // 重载触发 Kimi 网页刷新 token，再试一次
            await load(membershipHome, in: webView)
            do {
                return try await callBoth()
            } catch {
                UserDefaults.standard.set(false, forKey: Self.loggedInDefaultsKey)
                throw error
            }
        }
    }

    private func callBoth() async throws -> (stats: Data, subscription: Data) {
        let stats = try await call("GetSubscriptionStats")
        let sub = try await call("GetSubscription")
        return (stats, sub)
    }

    private func call(_ method: String) async throws -> Data {
        let js = """
        (async () => {
          const tok = localStorage.getItem('access_token');
          if (!tok) return JSON.stringify({__status: 401});
          const r = await fetch(
            'https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/\(method)',
            { method:'POST',
              headers:{'content-type':'application/json','authorization':'Bearer '+tok},
              body:'{}', credentials:'include' });
          const body = await r.text();
          return JSON.stringify({__status: r.status, body});
        })()
        """
        let raw = try await webView.evaluateJavaScript(js)
        guard let str = raw as? String,
              let data = str.data(using: .utf8),
              let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = env["__status"] as? Int else {
            throw ProbeError.invalidResponse("Kimi 网页会话未返回数据")
        }
        if status == 401 { throw ProbeError.authenticationRequired("请在设置中重新登录 Kimi 网页账号。") }
        guard status == 200, let body = env["body"] as? String else {
            throw ProbeError.requestFailed("Kimi 会员接口返回 \(status)")
        }
        return Data(body.utf8)
    }

    /// 弹窗让用户用平时的方式登录；检测到 access_token 即判定成功、关窗。
    func presentLogin() async {
        let loginWV = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 680),
                                configuration: {
                                    let c = WKWebViewConfiguration()
                                    c.websiteDataStore = .default()
                                    return c
                                }())
        loginWV.customUserAgent = webView.customUserAgent
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "登录 Kimi"
        window.contentView = loginWV
        window.center()
        window.level = .floating
        loginWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        loginWV.load(URLRequest(url: URL(string: "https://www.kimi.com/")!))

        // 轮询 access_token；最多 5 分钟
        for _ in 0..<300 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if window.isVisible == false { break }
            if let tok = (try? await loginWV.evaluateJavaScript(
                "localStorage.getItem('access_token')")) as? String, !tok.isEmpty {
                UserDefaults.standard.set(true, forKey: Self.loggedInDefaultsKey)
                await load(membershipHome, in: webView)   // 让常驻 WebView 同步会话
                break
            }
        }
        window.close()
        loginWindow = nil
    }

    func logout() async {
        UserDefaults.standard.set(false, forKey: Self.loggedInDefaultsKey)
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let kimi = records.filter { $0.displayName.contains("kimi") }
        await store.removeData(ofTypes: types, for: kimi)
        await load(URL(string: "about:blank")!, in: webView)
    }
}

private final class LoadDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void
    private var fired = false
    init(_ onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    private func fire() { if !fired { fired = true; onFinish() } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { fire() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fire() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fire() }
}
```

- [ ] **Step 3: 编译验证**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`。若报 `WKWebsiteDataStore.allWebsiteDataTypes()` 或并发相关错误，按编译器提示对齐（如给闭包加 `@MainActor` 或 `nonisolated`）。

（此任务无自动化测试 —— WKWebView 需真机会话，留待 Task 6 的手动验证。）

---

## Task 3: `KimiWebProbe` 探针

**Files:**
- Modify: `Sources/QuotaPeek/Providers/KimiWebProbe.swift`（在 Task 1 文件里追加探针）

**Interfaces:**
- Consumes: `KimiWebSession.shared.fetchMembership()`、`KimiMembershipParser.parse(...)`。
- Produces: `struct KimiWebProbe: ProviderProbe`，`provider = .kimi`，`source = .officialAPI`。

- [ ] **Step 1: 追加探针**

在 `Sources/QuotaPeek/Providers/KimiWebProbe.swift` 顶部（`enum KimiMembershipParser` 之前）加：

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

- [ ] **Step 2: 编译验证**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`。若报 `ProviderProbe` 的 `fetch()` actor 隔离不匹配（`KimiWebSession` 是 `@MainActor`），把 `KimiWebProbe.fetch()` 内的调用保持 `await` 即可 —— `fetch()` 是 async，会自动跳到主 actor。

- [ ] **Step 3: 确认已有测试仍通过**

Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 全部通过（含 Task 1 新增用例）。

---

## Task 4: `ProviderFactory` 路由

**Files:**
- Modify: `Sources/QuotaPeek/Providers/ProviderFactory.swift`

**Interfaces:**
- Consumes: `KimiWebProbe`（Task 3）、现有 `KimiProbe`、`UserDefaults` key `"QuotaPeek.kimiWebLoggedIn"`（= `KimiWebSession.loggedInDefaultsKey`，Task 2 写入）。
- Produces: 工厂对 Kimi 的路由分支。

登录状态的单一真相源是 `UserDefaults`（由 `KimiWebSession` 读写），**不**放进 `AppPreferences`——避免给合成 `Codable` 新增字段导致旧偏好 JSON 解码失败、`PreferencesStore.load()` 回退全默认而丢失用户其它设置。工厂直接读 `UserDefaults`。

- [ ] **Step 1: 改工厂路由**

`ProviderFactory.make` 的 Kimi 分支改为：

```swift
        if preferences.kimiEnabled {
            let loggedIn = UserDefaults.standard.bool(forKey: "QuotaPeek.kimiWebLoggedIn")
            if loggedIn {
                probes.append(KimiWebProbe())
            } else {
                probes.append(KimiProbe(executablePath: preferences.kimiExecutable))
            }
        }
```

- [ ] **Step 2: 编译 + 全测试**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: `Build complete!` 且测试全通过。

---

## Task 5: `AppModel` 桥接方法

**Files:**
- Modify: `Sources/QuotaPeek/App/AppModel.swift`（`hasGLMAPIKey()` 之后加方法）

**Interfaces:**
- Consumes: `KimiWebSession.shared`。
- Produces: `AppModel` 上的 `func kimiWebIsLoggedIn() -> Bool`、`func kimiLogin() async`、`func kimiLogout() async`。

- [ ] **Step 1: 加方法**

在 `Sources/QuotaPeek/App/AppModel.swift` 的 `hasGLMAPIKey()` 方法之后加：

```swift
    func kimiWebIsLoggedIn() -> Bool {
        UserDefaults.standard.bool(forKey: KimiWebSession.loggedInDefaultsKey)
    }

    func kimiLogin() async {
        await KimiWebSession.shared.presentLogin()
        objectWillChange.send()
        await refreshAll()
    }

    func kimiLogout() async {
        await KimiWebSession.shared.logout()
        objectWillChange.send()
        await refreshAll()
    }
```

- [ ] **Step 2: 编译验证**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`。

---

## Task 6: `SettingsView` Kimi 登录分区

**Files:**
- Modify: `Sources/QuotaPeek/UI/SettingsView.swift`

**Interfaces:**
- Consumes: `model.kimiWebIsLoggedIn()`、`model.kimiLogin()`、`model.kimiLogout()`（Task 5）。

- [ ] **Step 1: 加 Kimi 分区**

在 `SettingsView.swift` 的 `Section("GLM Coding Plan")` **之前**插入：

```swift
            Section("Kimi 网页账号") {
                HStack {
                    Text(model.kimiWebIsLoggedIn() ? "已登录（网页接口，含套餐名与月度额度）"
                                                    : "未登录（使用官方 CLI）")
                        .font(.caption)
                        .foregroundStyle(model.kimiWebIsLoggedIn() ? .green : .secondary)
                    Spacer()
                    if model.kimiWebIsLoggedIn() {
                        Button("退出登录") { Task { await model.kimiLogout() } }
                    } else {
                        Button("登录 Kimi 网页账号") { Task { await model.kimiLogin() } }
                    }
                }
                Text("登录后 Kimi 卡片改用网页会员接口，一次显示每月/每周/5 小时额度与套餐名；登录状态保存在本机，token 刷新由 Kimi 网页会话自动完成。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 2: 编译验证**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`。

- [ ] **Step 3: 打包并手动验证**

Run:
```bash
pkill -x QuotaPeek 2>/dev/null; scripts/build-app.sh >/dev/null 2>&1 && open dist/QuotaPeek.app
```
手动检查：
1. 打开设置 → “Kimi 网页账号”分区显示“未登录”，点“登录 Kimi 网页账号”弹出登录窗。
2. 用短信/微信/Google 正常登录，窗口自动关闭，状态变“已登录”。
3. 悬浮面板 Kimi 卡片出现“Allegro”套餐徽标 + 每月/每周/5 小时三行；数字与 kimi.com 网页面板一致。
4. 点“退出登录”，卡片回退到 CLI 的每周/5 小时两行，无套餐徽标。

---

## Self-Review

- **Spec coverage：** 解析器（Task 1）、WKWebView 会话含登录/fetch/401 重试/登出（Task 2）、探针（Task 3）、工厂路由（Task 4）、AppModel 桥接（Task 5）、设置 UI（Task 6）——覆盖 spec 的全部组件与错误处理。3 个窗口 + 套餐名断言在 Task 1 单测中落实。
- **占位符：** 无 TBD/TODO；每个改代码步骤都给了完整代码。
- **类型一致性：** `KimiMembershipParser.parse(stats:subscription:capturedAt:)`、`KimiWebSession.shared.fetchMembership() -> (stats:Data, subscription:Data)`、`KimiWebSession.loggedInDefaultsKey` 全程一致；UserDefaults key 字符串 `"QuotaPeek.kimiWebLoggedIn"` 在 Task 2/4/5 中统一（Task 5 引用 `KimiWebSession.loggedInDefaultsKey` 常量，其值即该字符串）。
- **注意点（Task 4）：** `kimiWebLoggedIn` **不进** `AppPreferences`，改用独立 `UserDefaults` key（`KimiWebSession.loggedInDefaultsKey`），避免给合成 `Codable` 加字段导致旧偏好解码回退丢失。
