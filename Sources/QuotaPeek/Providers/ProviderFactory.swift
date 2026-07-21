import Foundation

enum ProviderFactory {
    static func make(preferences: AppPreferences, glmAPIKey: String?) -> [any ProviderProbe] {
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
        return probes
    }
}
