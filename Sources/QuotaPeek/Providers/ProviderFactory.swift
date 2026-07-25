import Foundation

@MainActor
enum ProviderFactory {
    static func make(
        accounts: [ProviderAccount],
        executablePaths: (codex: String, claude: String, kimi: String),
        secret: (ProviderAccount) -> String?,
        kimiWebSession: (ProviderAccount) -> KimiWebSession
    ) -> [(account: ProviderAccount, probe: any ProviderProbe)] {
        accounts.filter(\.enabled).compactMap { account -> (account: ProviderAccount, probe: any ProviderProbe)? in
            switch (account.provider, account.credential) {
            case (.codex, .cliHome(let path)):
                return (account, CodexProbe(executablePath: executablePaths.codex, homeDirectory: path))
            case (.claude, .cliHome(let path)):
                return (account, ClaudeProbe(executablePath: executablePaths.claude, homeDirectory: path))
            case (.kimi, .kimi(let cliHomePath)):
                let session = kimiWebSession(account)
                if session.isLoggedIn {
                    return (account, KimiWebProbe(session: session))
                }
                return (account, KimiProbe(executablePath: executablePaths.kimi, homeDirectory: cliHomePath))
            case (.glm, .apiKey(let baseURL)):
                return (account, GLMProbe(baseURL: baseURL, apiKey: secret(account)))
            case (.grok, .cookie):
                return (account, GrokProbe(cookie: secret(account)))
            default:
                return nil
            }
        }
    }
}
