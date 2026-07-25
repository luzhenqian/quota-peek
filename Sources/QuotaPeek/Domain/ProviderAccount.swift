import Foundation

struct ProviderAccount: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var provider: ProviderID
    var label: String
    var credential: AccountCredential
    var enabled: Bool = true
}

enum AccountCredential: Codable, Equatable, Sendable {
    case cliHome(path: String)      // Claude / Codex：CLI 配置目录路径，空串 = 用 CLI 自己的默认目录
    case kimi(cliHomePath: String)  // Kimi：同上的 CLI 目录；是否叠加网页登录由 per-account 的
                                     // UserDefaults 标志位判断（见 KimiWebSession），不在这里存
    case apiKey(baseURL: String)    // GLM：密钥本身存 Keychain，这里只留 base URL
    case cookie                     // Grok：密钥本身存 Keychain
}

extension ProviderAccount {
    /// 迁移旧版单账号配置时使用的固定 UUID，每个 Provider 各一个。
    /// 固定值保证 Keychain key、WKWebsiteDataStore identifier 等派生值
    /// 在多次启动 / 重复迁移之间保持稳定、幂等（不会每次启动生成新账号）。
    static func legacyDefaultID(for provider: ProviderID) -> UUID {
        switch provider {
        case .codex:  UUID(uuidString: "6D1A1000-0000-4000-8000-000000000001")!
        case .claude: UUID(uuidString: "6D1A1000-0000-4000-8000-000000000002")!
        case .kimi:   UUID(uuidString: "6D1A1000-0000-4000-8000-000000000003")!
        case .glm:    UUID(uuidString: "6D1A1000-0000-4000-8000-000000000004")!
        case .grok:   UUID(uuidString: "6D1A1000-0000-4000-8000-000000000005")!
        }
    }

    /// Keychain 存取用的账号字符串；只有 GLM/Grok 这类密钥型凭证需要，其余返回 nil。
    var keychainKey: String? {
        switch (provider, credential) {
        case (.glm, .apiKey): "glm-api-key-\(id.uuidString)"
        case (.grok, .cookie): "grok-cookie-\(id.uuidString)"
        default: nil
        }
    }
}

extension AccountCredential {
    /// CLI 类凭证的登录目录路径；非 CLI 凭证返回 nil。用于把同目录的探针分到一组顺序重试。
    var cliHomeDirectory: String? {
        switch self {
        case .cliHome(let path): path
        case .kimi(let path): path
        case .apiKey, .cookie: nil
        }
    }
}
