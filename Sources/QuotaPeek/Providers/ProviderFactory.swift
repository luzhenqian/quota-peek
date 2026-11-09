import Foundation

enum ProviderFactory {
    static func make(
        preferences: AppPreferences,
        glmAPIKey: String?,
        grokCookie: String?,
        deepSeekAPIKey: String?
    ) -> [any ProviderProbe] {
        var probes: [any ProviderProbe] = []
        if preferences.codexEnabled {
            probes.append(CodexProbe(executablePath: preferences.codexExecutable))
        }
        if preferences.claudeEnabled {
            probes.append(ClaudeProbe(executablePath: preferences.claudeExecutable))
        }
        if preferences.kimiEnabled {
            if KimiWebSession.isLoggedIn {
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
        if preferences.deepSeekEnabled {
            // DeepSeek 没有订阅额度窗口，官方 API 只返回按量计费账户的可用余额。
            probes.append(DeepSeekProbe(apiKey: deepSeekAPIKey))
        }
        return probes
    }
}
