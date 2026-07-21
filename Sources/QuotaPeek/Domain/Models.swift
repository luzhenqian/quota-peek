import Foundation

enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case kimi
    case glm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .kimi: "Kimi"
        case .glm: "GLM Coding Plan"
        }
    }

    var shortName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .kimi: "Kimi"
        case .glm: "GLM"
        }
    }

    var symbolName: String {
        switch self {
        case .codex: "sparkles"
        case .claude: "brain.head.profile"
        case .kimi: "moon.stars.fill"
        case .glm: "cube.transparent.fill"
        }
    }

    var logoName: String {
        switch self {
        case .codex: "openai"
        case .claude: "claude"
        case .kimi: "kimi"
        case .glm: "zhipu"
        }
    }

    /// 把套餐名归入等级。同一套餐词跨 provider 等级不同，必须分家判断：
    /// - ChatGPT/Codex: free < go < plus < pro < team < enterprise（pro 是个人顶级）
    /// - Claude:        free < pro < max < team < enterprise（pro 入门，max 顶级）
    /// - Kimi:          adagio/andante < moderato < allegretto < allegro < vivace
    /// - GLM:           lite < pro < max（pro 中端，max 顶级）
    func planTier(for plan: String) -> PlanTier {
        let p = plan.lowercased()
        switch self {
        case .codex:
            if p.contains("pro") || p.contains("enterprise") { return .top }
            if p.contains("team") || p.contains("business") { return .high }
            if p.contains("plus") { return .mid }
            return .base
        case .claude:
            if p.contains("max") || p.contains("enterprise") { return .top }
            if p.contains("team") { return .high }
            if p.contains("pro") { return .mid }
            return .base
        case .kimi:
            // allegro 不是 allegretto 的子串，判断互不干扰
            if p.contains("vivace") || p.contains("allegro") { return .top }
            if p.contains("allegretto") { return .high }
            if p.contains("moderato") { return .mid }
            return .base
        case .glm:
            if p.contains("max") || p.contains("ultra") { return .top }
            if p.contains("pro") { return .mid }
            return .base
        }
    }
}

/// 套餐等级（从低到高），用于给套餐徽标分色。
enum PlanTier: Sendable {
    case base, mid, high, top
}

enum QuotaWindowKind: Hashable, Codable, Sendable {
    case session
    case weekly
    case monthly
    case model(String)
    case tools

    var displayName: String {
        switch self {
        case .session: "5 小时"
        case .weekly: "每周"
        case .monthly: "每月"
        case .model(let name): name
        case .tools: "MCP / 工具"
        }
    }
}

struct QuotaWindow: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var kind: QuotaWindowKind
    var remainingPercent: Double
    var resetsAt: Date?
    var resetDescription: String?

    init(
        id: String? = nil,
        kind: QuotaWindowKind,
        remainingPercent: Double,
        resetsAt: Date? = nil,
        resetDescription: String? = nil
    ) {
        self.id = id ?? kind.displayName
        self.kind = kind
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }
}

struct ProviderBalance: Hashable, Codable, Sendable {
    var remaining: Decimal
    var currency: String
    var limit: Decimal?

    var formattedRemaining: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        return formatter.string(from: remaining as NSDecimalNumber)
            ?? "\(currency) \(remaining)"
    }
}

enum SnapshotSource: String, Codable, Sendable {
    case cli = "官方 CLI"
    case localRPC = "本地 RPC"
    case officialAPI = "官方 API"
    case cache = "本地缓存"
}

struct ProviderSnapshot: Identifiable, Hashable, Codable, Sendable {
    var id: ProviderID { provider }
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

    var isStale: Bool {
        Date().timeIntervalSince(capturedAt) > 30 * 60
    }

    static func failure(
        provider: ProviderID,
        message: String,
        source: SnapshotSource,
        previous: ProviderSnapshot? = nil
    ) -> ProviderSnapshot {
        var snapshot = previous ?? ProviderSnapshot(
            provider: provider,
            windows: [],
            balance: nil,
            plan: nil,
            account: nil,
            source: source,
            capturedAt: Date(),
            errorMessage: nil
        )
        snapshot.errorMessage = message
        return snapshot
    }
}

enum ProbeError: LocalizedError, Sendable {
    case executableNotFound(String)
    case authenticationRequired(String)
    case timedOut(String)
    case invalidResponse(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name): "未找到 \(name)，请先安装或在设置中指定路径。"
        case .authenticationRequired(let hint): "需要登录或配置凭证。\(hint)"
        case .timedOut(let name): "\(name) 查询超时，请稍后重试。"
        case .invalidResponse(let reason): "无法解析额度数据：\(reason)"
        case .requestFailed(let reason): "查询失败：\(reason)"
        }
    }
}

struct ProviderResult: Sendable {
    let provider: ProviderID
    let snapshot: ProviderSnapshot?
    let errorMessage: String?
    let source: SnapshotSource
}

protocol ProviderProbe: Sendable {
    var provider: ProviderID { get }
    var source: SnapshotSource { get }
    func fetch() async throws -> ProviderSnapshot
}
