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

        guard let limits = response.data?.limits, !limits.isEmpty else {
            throw ProbeError.invalidResponse("GLM 没有返回 limits")
        }

        let windows = limits.compactMap { item -> QuotaWindow? in
            let kind: QuotaWindowKind
            switch (item.type, item.unit) {
            case ("TIME_LIMIT", _): kind = .tools
            case ("TOKENS_LIMIT", 3), ("TOKENS_LIMIT", nil): kind = .session
            case ("TOKENS_LIMIT", 6): kind = .weekly
            case ("TOKENS_LIMIT", 7): kind = .monthly
            case ("TOKENS_LIMIT", let unit?): kind = .model("Token 单元 \(unit)")
            default: return nil
            }

            let reset = item.nextResetTime?.date
            return QuotaWindow(
                kind: kind,
                remainingPercent: 100 - item.percentage,
                resetsAt: reset,
                resetDescription: reset?.quotaCountdown
            )
        }

        guard !windows.isEmpty else {
            throw ProbeError.invalidResponse("GLM 返回了未知的额度类型")
        }

        return ProviderSnapshot(
            provider: .glm,
            windows: windows,
            balance: nil,
            plan: nil,
            account: nil,
            source: .officialAPI,
            capturedAt: capturedAt,
            errorMessage: nil
        )
    }
}

private struct GLMQuotaResponse: Decodable {
    let data: GLMQuotaData?
}

private struct GLMQuotaData: Decodable {
    let limits: [GLMQuotaItem]?
}

private struct GLMQuotaItem: Decodable {
    let type: String
    let unit: Int?
    let percentage: Double
    let nextResetTime: FlexibleDate?
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
