import Foundation

@MainActor
enum ProviderFactory {
    static func make(preferences: AppPreferences, glmAPIKey: String?, grokCookie: String?) -> [any ProviderProbe] {
        var probes: [any ProviderProbe] = []
        if preferences.codexEnabled {
            probes.append(CodexProbe(executablePath: preferences.codexExecutable))
        }
        if preferences.claudeEnabled {
            probes.append(ClaudeProbe(executablePath: preferences.claudeExecutable))
        }
        if preferences.kimiEnabled {
            if KimiWebSession.shared.isLoggedIn {
                probes.append(KimiWebProbe())
            } else {
                probes.append(KimiProbe(executablePath: preferences.kimiExecutable))
            }
        }
        if preferences.glmEnabled {
            probes.append(GLMProbe(baseURL: preferences.glmBaseURL, apiKey: glmAPIKey))
        }
        if preferences.grokEnabled {
            // Grok 无 CLI；URLSession 直连 API，带用户粘贴的 grok.com Cookie。
            probes.append(GrokProbe(cookie: grokCookie))
        }
        return probes
    }
}

extension ProviderFactory {
    @MainActor
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
