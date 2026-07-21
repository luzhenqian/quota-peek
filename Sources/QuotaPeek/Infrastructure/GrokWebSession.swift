import AppKit
import WebKit

/// 内嵌 WKWebView 持有 grok.com 登录态，直连其额度接口。
/// 与 KimiWebSession 同构，但 Grok 用 cookie 认证（同源 fetch 自动带 cookie），
/// 无需读取 localStorage token。
@MainActor
final class GrokWebSession: NSObject {
    static let shared = GrokWebSession()

    nonisolated private static let loggedInDefaultsKey = "QuotaPeek.grokWebLoggedIn"
    private let home = URL(string: "https://grok.com/")!

    /// 登录状态的唯一真相源。只读写 UserDefaults（线程安全），故 nonisolated。
    nonisolated static var isLoggedIn: Bool {
        get { UserDefaults.standard.bool(forKey: loggedInDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: loggedInDefaultsKey) }
    }

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        return wv
    }()

    private override init() { super.init() }

    private func ensureLoaded() async {
        if webView.url?.host == "grok.com" { return }
        await load(home, in: webView)
    }

    // 串行化导航，避免并发 load 覆盖 weak navigationDelegate 导致挂起（详见 KimiWebSession）。
    private var loadChain: Task<Void, Never>?
    private var retainedDelegate: LoadDelegate?

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

    /// 拉取各模型的每日/滚动额度 + 登录态，聚合成一个 JSON。cookie 认证，无需 token。
    func fetchRateLimits() async throws -> Data {
        await ensureLoaded()
        let js = """
        const models = [
          {name: 'grok-4', label: 'Grok 4'},
          {name: 'grok-3', label: 'Grok 3'},
          {name: 'grok-4-heavy', label: 'Grok 4 Heavy'}
        ];
        // 登录检测：subscriptions 需登录，200 即已登录
        const sub = await fetch('https://grok.com/rest/subscriptions', { credentials: 'include' });
        const loggedIn = sub.status === 200;
        const windows = [];
        if (loggedIn) {
          for (const m of models) {
            const r = await fetch('https://grok.com/rest/rate-limits', {
              method: 'POST', credentials: 'include',
              headers: { 'content-type': 'application/json' },
              body: JSON.stringify({ requestKind: 'DEFAULT', modelName: m.name }) });
            if (r.status === 200) {
              const j = await r.json();
              windows.push({ label: m.label, remaining: j.remainingQueries,
                             total: j.totalQueries, windowSizeSeconds: j.windowSizeSeconds });
            }
          }
        }
        return JSON.stringify({ loggedIn, windows });
        """
        let raw = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
        guard let str = raw as? String, let data = str.data(using: .utf8) else {
            throw ProbeError.invalidResponse("Grok 网页会话未返回数据")
        }
        return data
    }

    /// 弹窗让用户登录 grok.com；检测到 subscriptions 可访问即判定成功、关窗。
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
        window.title = "登录 Grok"
        window.isReleasedWhenClosed = false
        window.contentView = loginWV
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        loginWV.load(URLRequest(url: home))

        for _ in 0..<300 {
            try? await Task.sleep(for: .seconds(1))
            if window.isVisible == false { break }
            let js = "(await fetch('https://grok.com/rest/subscriptions',{credentials:'include'})).status === 200"
            if let ok = (try? await loginWV.callAsyncJavaScript(
                js, arguments: [:], in: nil, contentWorld: .page)) as? Bool, ok {
                Self.isLoggedIn = true
                await load(home, in: webView)   // 同步常驻 WebView 会话
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
        let grok = records.filter { $0.displayName.localizedCaseInsensitiveContains("grok") }
        await store.removeData(ofTypes: types, for: grok)
        await load(URL(string: "about:blank")!, in: webView)
    }
}
