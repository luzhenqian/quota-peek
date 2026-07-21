import AppKit
import WebKit

@MainActor
final class KimiWebSession: NSObject {
    static let shared = KimiWebSession()

    nonisolated private static let loggedInDefaultsKey = "QuotaPeek.kimiWebLoggedIn"
    private let membershipHome = URL(string: "https://www.kimi.com/membership/subscription")!

    /// 登录状态的唯一真相源：登录/登出时由本会话写入 UserDefaults，
    /// ProviderFactory 与 AppModel 都通过此属性读取，避免各处硬编码 key。
    /// 只读写 UserDefaults（线程安全），故 nonisolated，可从任意上下文访问。
    nonisolated static var isLoggedIn: Bool {
        get { UserDefaults.standard.bool(forKey: loggedInDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: loggedInDefaultsKey) }
    }

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

    private override init() { super.init() }

    /// 确保常驻 WebView 已停在 www.kimi.com（同源，才能带 token 直连接口）。
    private func ensureLoaded() async {
        if webView.url?.host == "www.kimi.com" { return }
        await load(membershipHome, in: webView)
    }

    /// 串行化所有 load() 调用：WKWebView.navigationDelegate 是 weak 属性，
    /// 若两次 load() 并发（例如 presentLogin() 收尾与后台 refreshAll() 撞车），
    /// 后一次会覆盖 retainedDelegate、把前一次的 delegate 提前释放，
    /// 导致前一次的 withCheckedContinuation 永不 resume、任务永久挂起。
    /// 用一条任务链把导航串起来，保证同一时刻只有一个导航在跑，
    /// 单份 delegate 槽位才是安全的。
    private var loadChain: Task<Void, Never>?

    private func load(_ url: URL, in wv: WKWebView) async {
        let previous = loadChain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.performLoad(url, in: wv)
        }
        loadChain = task
        await task.value
    }

    private func performLoad(_ url: URL, in wv: WKWebView) async {
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
            } catch ProbeError.authenticationRequired {
                // 仍是 401 → session 真过期，标记未登录并抛出
                Self.isLoggedIn = false
                throw ProbeError.authenticationRequired("请在设置中重新登录 Kimi 网页账号。")
            }
            // 其它错误（网络/500）直接向上抛出，不翻登录标志 ——
            // 上一份好数据由 SnapshotStore 缓存保留，下次刷新自动重试。
        }
    }

    private func callBoth() async throws -> (stats: Data, subscription: Data) {
        // 两个接口相互独立，并发发起以减半刷新延迟。
        async let stats = call("GetSubscriptionStats")
        async let sub = call("GetSubscription")
        return try await (stats, sub)
    }

    private func call(_ method: String) async throws -> Data {
        // callAsyncJavaScript 把 body 包成 async 函数并 await 其返回值；
        // 必须用它而非 evaluateJavaScript —— 后者不会 await Promise，会报
        // WKErrorJavaScriptResultTypeIsUnsupported（“返回结果的类型不受支持”）。
        let js = """
        const tok = localStorage.getItem('access_token');
        if (!tok) return JSON.stringify({__status: 401});
        const r = await fetch(
          'https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/\(method)',
          { method:'POST',
            headers:{'content-type':'application/json','authorization':'Bearer '+tok},
            body:'{}', credentials:'include' });
        const body = await r.text();
        return JSON.stringify({__status: r.status, body});
        """
        let raw = try await webView.callAsyncJavaScript(
            js, arguments: [:], in: nil, contentWorld: .page)
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
        // 局部变量 window 持有窗口直到函数返回；若窗口在 close() 时自行释放，
        // 该强引用会指向已释放内存，导致自动释放池 drain 时过度释放崩溃。
        window.isReleasedWhenClosed = false
        window.contentView = loginWV
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        loginWV.load(URLRequest(url: URL(string: "https://www.kimi.com/")!))

        // 轮询 access_token；最多 5 分钟
        for _ in 0..<300 {
            try? await Task.sleep(for: .seconds(1))
            if window.isVisible == false { break }
            if let tok = (try? await loginWV.evaluateJavaScript(
                "localStorage.getItem('access_token')")) as? String, !tok.isEmpty {
                Self.isLoggedIn = true
                // 登录 WebView 写入 localStorage 到持久 data store、再到常驻 WebView
                // 可见有微小时序窗口；重载常驻 WebView 并确认能读到 token 后再返回，
                // 避免登录后首次 fetch 因 token 尚未同步而 401。
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
        Self.isLoggedIn = false
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let kimi = records.filter { $0.displayName.localizedCaseInsensitiveContains("kimi") }
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
