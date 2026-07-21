import Foundation

/// Grok 无官方 CLI，且内嵌 WebView 会被 xAI 的 Cloudflare bot 防护拦截。
/// 但纯 API 调用（/rest/rate-limits）Cloudflare 放行，只需 cookie 认证 ——
/// 故用 URLSession 直连，带用户从浏览器 DevTools 复制的 grok.com Cookie。
struct GrokProbe: ProviderProbe {
    let provider: ProviderID = .grok
    let source: SnapshotSource = .officialAPI

    private let cookie: String?
    private let session = URLSession(configuration: .ephemeral)

    private static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // grok-4 免费 7/24h、grok-3 30/24h、grok-4-heavy 20/2h（订阅账号数值更高）。
    private static let models: [(name: String, label: String)] = [
        ("grok-4", "Grok 4"),
        ("grok-3", "Grok 3"),
        ("grok-4-heavy", "Grok 4 Heavy"),
    ]

    init(cookie: String?) {
        self.cookie = cookie
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let cookie, !cookie.isEmpty else {
            throw ProbeError.authenticationRequired("请在设置中粘贴 Grok Cookie。")
        }

        let plan = await fetchPlan(cookie: cookie)

        var windows: [QuotaWindow] = []
        for model in Self.models {
            let data = try await callRateLimit(modelName: model.name, cookie: cookie)
            if let window = try GrokRateLimitParser.window(label: model.label, from: data) {
                windows.append(window)
            }
        }

        guard !windows.isEmpty else {
            throw ProbeError.invalidResponse("Grok 未返回额度数据")
        }

        return ProviderSnapshot(
            provider: .grok,
            windows: windows,
            balance: nil,
            plan: plan,
            account: nil,
            source: .officialAPI,
            capturedAt: Date(),
            errorMessage: nil
        )
    }

    /// 查订阅状态标注层级：空 → Free，非空 → SuperGrok。容错，失败返回 nil。
    private func fetchPlan(cookie: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://grok.com/rest/subscriptions")!)
        request.setValue(cookie, forHTTPHeaderField: "cookie")
        request.setValue(Self.browserUA, forHTTPHeaderField: "user-agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subs = obj["subscriptions"] as? [Any] else {
            return nil
        }
        return subs.isEmpty ? "Free" : "SuperGrok"
    }

    private func callRateLimit(modelName: String, cookie: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://grok.com/rest/rate-limits")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(cookie, forHTTPHeaderField: "cookie")
        request.setValue(Self.browserUA, forHTTPHeaderField: "user-agent")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["requestKind": "DEFAULT", "modelName": modelName])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw ProbeError.authenticationRequired("Grok Cookie 已失效，请在设置中重新粘贴。")
        }
        guard status == 200 else {
            throw ProbeError.requestFailed("Grok 接口返回 \(status)")
        }
        return data
    }
}

enum GrokRateLimitParser {
    private struct RateLimit: Decodable {
        let remainingQueries: Int?
        let totalQueries: Int?
        let windowSizeSeconds: Int?
    }

    /// 把单个 rate-limits 响应映射成一个额度窗口。total 为 0（该模型不可用）时返回 nil。
    static func window(label: String, from data: Data) throws -> QuotaWindow? {
        let limit = try JSONDecoder().decode(RateLimit.self, from: data)
        guard let total = limit.totalQueries, total > 0 else { return nil }
        let remaining = limit.remainingQueries ?? 0
        let hours = (limit.windowSizeSeconds ?? 0) / 3_600
        // Grok 接口只给窗口时长和剩余次数，不给重置时间戳，故用描述而非倒计时。
        return QuotaWindow(
            kind: .model(label),
            remainingPercent: Double(remaining) / Double(total) * 100,
            resetsAt: nil,
            resetDescription: "\(hours) 小时窗口 · 剩 \(remaining)/\(total)"
        )
    }
}
