import Foundation

struct GrokWebProbe: ProviderProbe {
    let provider: ProviderID = .grok
    let source: SnapshotSource = .officialAPI

    func fetch() async throws -> ProviderSnapshot {
        let data = try await GrokWebSession.shared.fetchRateLimits()
        return try GrokRateLimitParser.parse(data)
    }
}

enum GrokRateLimitParser {
    private struct Payload: Decodable {
        struct Window: Decodable {
            let label: String
            let remaining: Int?
            let total: Int?
            let windowSizeSeconds: Int?
        }
        let loggedIn: Bool
        let windows: [Window]
    }

    static func parse(_ data: Data, capturedAt: Date = Date()) throws -> ProviderSnapshot {
        let payload = try JSONDecoder().decode(Payload.self, from: data)

        guard payload.loggedIn else {
            GrokWebSession.isLoggedIn = false
            throw ProbeError.authenticationRequired("请在设置中登录 Grok 账号。")
        }

        let windows = payload.windows.map { w -> QuotaWindow in
            let total = w.total ?? 0
            let remaining = w.remaining ?? 0
            let percent = total > 0 ? Double(remaining) / Double(total) * 100 : 100
            let hours = (w.windowSizeSeconds ?? 0) / 3_600
            // Grok 接口只给窗口时长和剩余次数，不给重置时间戳，故用描述而非倒计时。
            return QuotaWindow(
                kind: .model(w.label),
                remainingPercent: percent,
                resetsAt: nil,
                resetDescription: "\(hours) 小时窗口 · 剩 \(remaining)/\(total)"
            )
        }

        guard !windows.isEmpty else {
            throw ProbeError.invalidResponse("Grok 未返回额度数据")
        }

        return ProviderSnapshot(
            provider: .grok,
            windows: windows,
            balance: nil,
            plan: nil,   // 免费层无套餐；订阅信息接口对免费账号返回空
            account: nil,
            source: .officialAPI,
            capturedAt: capturedAt,
            errorMessage: nil
        )
    }
}
