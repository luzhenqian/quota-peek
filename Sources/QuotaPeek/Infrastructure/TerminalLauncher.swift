import Foundation

/// 新增 CLI 类账号时需要用户实际登录一次；不在应用内自动化这段交互
/// （各家 CLI 登录流程不一样、大多涉及浏览器跳转，硬编码自动化脆弱），
/// 而是拉起系统 Terminal.app 让用户像平时一样登录，交互交给 CLI 自己处理。
enum TerminalLauncher {
    static func loginCommand(provider: ProviderID, homeDirectory: String) -> String {
        switch provider {
        case .claude: #"CLAUDE_CONFIG_DIR="\#(homeDirectory)" claude"#
        case .codex:  #"CODEX_HOME="\#(homeDirectory)" codex login"#
        case .kimi:   #"KIMI_CODE_HOME="\#(homeDirectory)" kimi login"#
        case .glm, .grok: ""  // 非 CLI 类型，调用方不应该传进来
        }
    }

    static func appleScript(for command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
    }

    /// 副作用：真的拉起 Terminal.app。失败静默——用户可以自己开 Terminal 手动敲命令。
    static func run(command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript(for: command)]
        try? process.run()
    }
}
