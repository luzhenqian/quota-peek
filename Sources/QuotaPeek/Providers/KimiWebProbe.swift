import Foundation

struct KimiWebProbe: ProviderProbe {
    let provider: ProviderID = .kimi
    let source: SnapshotSource = .officialAPI
    let session: KimiWebSession

    @MainActor
    init(session: KimiWebSession = .shared) {
        self.session = session
    }

    func fetch() async throws -> ProviderSnapshot {
        let (stats, sub) = try await session.fetchMembership()
        return try KimiMembershipParser.parse(stats: stats, subscription: sub)
    }
}

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

    private static func window(kind: QuotaWindowKind, usedRatio: Double?, resetRaw: String?) -> QuotaWindow {
        let used = usedRatio ?? 0
        let reset = resetRaw.flatMap(TextParsing.iso8601Date(from:))
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
        // 套餐名可选：免费/无订阅账号仍有额度窗口，只是没有套餐徽标。
        let rawPlan = subDecoded?.subscription?.goods?.title
        let plan = (rawPlan?.isEmpty == false) ? rawPlan : nil

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
