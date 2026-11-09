import Foundation

struct DeepSeekProbe: ProviderProbe {
    let provider: ProviderID = .deepseek
    let source: SnapshotSource = .officialAPI

    private let apiKey: String?
    private let session = URLSession(configuration: .ephemeral)

    init(apiKey: String?) {
        self.apiKey = apiKey
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let credential = DeepSeekCredentialResolver.resolve(explicit: apiKey), !credential.isEmpty else {
            throw ProbeError.authenticationRequired("请在设置中保存 DeepSeek API Key。")
        }

        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProbeError.invalidResponse("DeepSeek 未返回 HTTP 响应")
        }
        switch http.statusCode {
        case 200..<300:
            return try DeepSeekBalanceParser.parse(data)
        case 401, 403:
            throw ProbeError.authenticationRequired("DeepSeek API Key 无效或已失效。")
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProbeError.requestFailed("DeepSeek HTTP \(http.statusCode) \(body.prefix(120))")
        }
    }
}

enum DeepSeekCredentialResolver {
    static func resolve(explicit: String?) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        guard let value = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum DeepSeekBalanceParser {
    static func parse(_ data: Data, capturedAt: Date = Date()) throws -> ProviderSnapshot {
        let response: DeepSeekBalanceResponse
        do {
            response = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
        } catch {
            throw ProbeError.invalidResponse("DeepSeek JSON 格式错误：\(error.localizedDescription)")
        }

        guard let item = response.balanceInfos.first else {
            throw ProbeError.invalidResponse("DeepSeek 没有返回 balance_infos")
        }
        guard let amount = Decimal(
            string: item.totalBalance,
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            throw ProbeError.invalidResponse("DeepSeek total_balance 不是有效金额")
        }

        return ProviderSnapshot(
            provider: .deepseek,
            windows: [],
            balance: ProviderBalance(
                remaining: max(0, amount),
                currency: item.currency.uppercased(),
                limit: nil
            ),
            plan: nil,
            account: nil,
            source: .officialAPI,
            capturedAt: capturedAt,
            errorMessage: nil
        )
    }
}

private struct DeepSeekBalanceResponse: Decodable {
    let isAvailable: Bool
    let balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

private struct DeepSeekBalanceInfo: Decodable {
    let currency: String
    let totalBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
    }
}
