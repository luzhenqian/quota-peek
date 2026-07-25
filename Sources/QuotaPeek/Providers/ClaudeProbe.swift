import Foundation

struct ClaudeProbe: ProviderProbe {
    let provider: ProviderID = .claude
    let source: SnapshotSource = .cli

    private let executablePath: String
    private let homeDirectory: String
    private let runner = ProcessRunner()

    init(executablePath: String, homeDirectory: String = "") {
        self.executablePath = executablePath
        self.homeDirectory = homeDirectory
    }

    static func environmentOverrides(homeDirectory: String) -> [String: String] {
        var overrides = ["ANTHROPIC_API_KEY": "", "ANTHROPIC_AUTH_TOKEN": "", "ANTHROPIC_BASE_URL": ""]
        if !homeDirectory.isEmpty { overrides["CLAUDE_CONFIG_DIR"] = homeDirectory }
        return overrides
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let executable = CommandLocator.locate("claude", explicitPath: executablePath) else {
            throw ProbeError.executableNotFound("Claude Code")
        }
        let workingDirectory = try probeWorkingDirectory()

        let result = try await runner.run(
            executable: executable,
            arguments: ["/usage", "--allowed-tools", "", "--ax-screen-reader"],
            input: "\r",
            timeout: 14,
            pseudoTerminal: true,
            closeInput: false,
            inputDelay: 0.2,
            inputReadyText: "Quick safety check",
            inputReadyTimeout: 5,
            skipInputIfNotReady: true,
            workingDirectory: workingDirectory,
            environment: Self.environmentOverrides(homeDirectory: homeDirectory)
        )

        if result.timedOut && result.text.isEmpty {
            throw ProbeError.timedOut("Claude")
        }
        return try ClaudeUsageParser.parse(result.text)
    }

    private func probeWorkingDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("QuotaPeek", isDirectory: true)
            .appendingPathComponent("ClaudeProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

}

enum ClaudeUsageParser {
    static func parse(_ rawText: String, capturedAt: Date = Date()) throws -> ProviderSnapshot {
        let text = TextParsing.stripANSI(rawText)
        let lower = text.lowercased()
        if lower.contains("/usage is only available for subscription plans") {
            throw ProbeError.invalidResponse("当前是 API 计费账户，不是 Claude Pro/Max 订阅")
        }
        if lower.contains("login required") || lower.contains("not logged in") {
            throw ProbeError.authenticationRequired("请先运行 claude 并登录。")
        }

        let lines = text.components(separatedBy: .newlines)
        let definitions: [(labels: [String], kind: QuotaWindowKind)] = [
            (["Current session"], .session),
            (["Current week (all models)"], .weekly),
            (["Current week (Opus)"], .model("Opus")),
            (["Current week (Sonnet only)", "Current week (Sonnet)"], .model("Sonnet")),
            (["Current week (Fable"], .model("Fable"))
        ]

        var windows: [QuotaWindow] = []
        for definition in definitions {
            guard let index = lines.firstIndex(where: { line in
                definition.labels.contains { line.localizedCaseInsensitiveContains($0) }
            }) else { continue }

            let candidates = Array(lines.dropFirst(index).prefix(12))
            guard let remaining = candidates.compactMap(TextParsing.percentRemaining).first else { continue }
            let resetText = TextParsing.resetText(near: index, lines: lines)
            let resetsAt = resetText.flatMap { text in
                TextParsing.relativeResetDate(from: text, now: capturedAt)
                    ?? TextParsing.absoluteResetDate(from: text, now: capturedAt)
            }
            windows.append(QuotaWindow(
                kind: definition.kind,
                remainingPercent: remaining,
                resetsAt: resetsAt,
                resetDescription: resetText
            ))
        }

        guard windows.contains(where: { $0.kind == .session }) else {
            throw ProbeError.invalidResponse("Claude /usage 输出中没有 Current session")
        }

        let plan: String?
        if lower.contains("claude max") { plan = "MAX" }
        else if lower.contains("claude pro") { plan = "PRO" }
        else { plan = nil }

        var balance: ProviderBalance?
        if let spentText = TextParsing.firstMatch(#"\$?([\d,.]+)\s*/\s*\$?([\d,.]+)\s*spent"#, in: text),
           let full = TextParsing.firstMatch(#"\$?[\d,.]+\s*/\s*\$?([\d,.]+)\s*spent"#, in: text),
           let spent = Decimal(string: spentText.replacingOccurrences(of: ",", with: "")),
           let limit = Decimal(string: full.replacingOccurrences(of: ",", with: "")) {
            balance = ProviderBalance(remaining: max(0, limit - spent), currency: "USD", limit: limit)
        }

        return ProviderSnapshot(
            provider: .claude,
            windows: windows,
            balance: balance,
            plan: plan,
            account: nil,
            source: .cli,
            capturedAt: capturedAt,
            errorMessage: nil
        )
    }
}
