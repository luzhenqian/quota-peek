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
