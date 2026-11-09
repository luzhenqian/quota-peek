import Foundation

struct GLMProbe: ProviderProbe {
    let provider: ProviderID = .glm
    let source: SnapshotSource = .officialAPI

    private let baseURL: String
    private let apiKey: String?

    init(baseURL: String, apiKey: String?) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let credential = GLMCredentialResolver.resolve(explicit: apiKey), !credential.isEmpty else {
            throw ProbeError.authenticationRequired("请在设置中保存 GLM Coding Plan API Key。")
        }
        guard let base = URL(string: baseURL),
              let host = base.host,
              let url = URL(string: "\(base.scheme ?? "https")://\(host)/api/monitor/usage/quota/limit") else {
            throw ProbeError.requestFailed("GLM Base URL 无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue(credential, forHTTPHeaderField: "Authorization")
        request.setValue("zh-CN,zh", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProbeError.invalidResponse("GLM 未返回 HTTP 响应")
        }
        switch http.statusCode {
        case 200..<300:
            return try GLMQuotaParser.parse(data)
        case 401, 403:
            throw ProbeError.authenticationRequired("GLM API Key 无效或已过期。")
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProbeError.requestFailed("GLM HTTP \(http.statusCode) \(body.prefix(120))")
        }
    }
}

enum GLMCredentialResolver {
    static func resolve(explicit: String?) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        if let environment = ProcessInfo.processInfo.environment["ANTHROPIC_AUTH_TOKEN"], !environment.isEmpty {
            return environment
        }

        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = object["env"] as? [String: Any],
              let token = env["ANTHROPIC_AUTH_TOKEN"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }
}

enum GLMQuotaParser {
    static func parse(_ data: Data, capturedAt: Date = Date()) throws -> ProviderSnapshot {
        let response: GLMQuotaResponse
        do {
            response = try JSONDecoder().decode(GLMQuotaResponse.self, from: data)
        } catch {
            throw ProbeError.invalidResponse("GLM JSON 格式错误：\(error.localizedDescription)")
        }

        if response.success == false || (response.code.map { $0 != 200 } ?? false) {
            let message = response.msg ?? "未知错误"
            throw ProbeError.invalidResponse("GLM 返回错误：\(message)")
        }

        guard let limits = response.data?.limits, !limits.isEmpty else {
            throw ProbeError.invalidResponse("GLM 没有返回 limits")
        }

        let windows = limits.map { item -> QuotaWindow in
            let reset = item.nextResetTime?.date
            return QuotaWindow(
                kind: item.windowKind,
                remainingPercent: item.remainingPercent,
                resetsAt: reset,
                resetDescription: reset?.quotaCountdown
            )
        }

        return ProviderSnapshot(
            provider: .glm,
            windows: windows,
            balance: nil,
            plan: response.data?.level?.uppercased(),
            account: nil,
            source: .officialAPI,
            capturedAt: capturedAt,
            errorMessage: nil
        )
    }
}

private struct GLMQuotaResponse: Decodable {
    let code: Int?
    let msg: String?
    let success: Bool?
    let data: GLMQuotaData?
}

private struct GLMQuotaData: Decodable {
    let limits: [GLMQuotaItem]?
    /// 订阅档位，例如 "lite" / "pro" / "max"。
    let level: String?
}

private struct GLMQuotaItem: Decodable {
    /// 线上取值为 "CREDIT_LIMIT"；早期版本见过 "TOKENS_LIMIT" / "TIME_LIMIT"。
    /// 除 TIME_LIMIT 外一律按周期窗口处理，避免 GLM 改名后整张卡片解析失败。
    let type: String
    /// 周期单位：3=小时，6=周，7=月。
    let unit: Int?
    /// 周期长度，配合 unit 使用（unit=3 & number=5 即“每 5 小时”）。
    let number: Int?
    /// 该窗口的总额度。
    let usage: Double?
    /// 已消耗额度。
    let currentValue: Double?
    let remaining: Double?
    /// 已用百分比（整数粒度）。
    let percentage: Double
    let nextResetTime: FlexibleDate?

    var windowKind: QuotaWindowKind {
        if type == "TIME_LIMIT" { return .tools }
        switch unit {
        case 3, nil:
            guard let number, number != 5 else { return .session }
            return .model("\(number) 小时")
        case 6:
            guard let number, number != 1 else { return .weekly }
            return .model("\(number) 周")
        case 7:
            guard let number, number != 1 else { return .monthly }
            return .model("\(number) 个月")
        case let unit?:
            return .model("额度单元 \(unit)")
        }
    }

    /// 优先用 remaining/usage 计算（percentage 只有整数精度），缺字段时回退到 percentage。
    var remainingPercent: Double {
        let value: Double
        if let usage, usage > 0, let remaining {
            value = remaining / usage * 100
        } else {
            value = 100 - percentage
        }
        return min(100, max(0, value))
    }
}

private enum FlexibleDate: Decodable {
    case milliseconds(Int64)
    case text(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .milliseconds(value)
        } else if let value = try? container.decode(String.self) {
            self = .text(value)
        } else {
            throw DecodingError.typeMismatch(
                FlexibleDate.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected timestamp or date string")
            )
        }
    }

    var date: Date? {
        switch self {
        case .milliseconds(let value):
            let seconds = value > 10_000_000_000 ? Double(value) / 1_000 : Double(value)
            return Date(timeIntervalSince1970: seconds)
        case .text(let value):
            if let result = TextParsing.iso8601Date(from: value) { return result }
            if let timestamp = Double(value) { return Date(timeIntervalSince1970: timestamp) }
            return nil
        }
    }
}
