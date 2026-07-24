import Foundation

struct KimiProbe: ProviderProbe {
    let provider: ProviderID = .kimi
    let source: SnapshotSource = .cli

    private let executablePath: String
    private let runner = ProcessRunner()

    init(executablePath: String) {
        self.executablePath = executablePath
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let executable = CommandLocator.locate("kimi", explicitPath: executablePath) else {
            throw ProbeError.executableNotFound("Kimi CLI")
        }

        let result = try await runner.run(
            executable: executable,
            arguments: [],
            input: "/usage\r",
            timeout: 14,
            pseudoTerminal: true,
            closeInput: false,
            inputDelay: 0.2,
            inputReadyText: "Send /help for help information.",
            inputReadyTimeout: 8
        )

        if result.timedOut && result.text.isEmpty {
            throw ProbeError.timedOut("Kimi")
        }
        return try KimiUsageParser.parse(result.text)
    }
}

enum KimiUsageParser {
    static func parse(_ rawText: String, capturedAt: Date = Date()) throws -> ProviderSnapshot {
        let text = TextParsing.stripANSI(rawText)
        let lower = text.lowercased()
        if lower.contains("not logged in") || lower.contains("login required") {
            throw ProbeError.authenticationRequired("请先运行 kimi login。")
        }

        let lines = text.components(separatedBy: .newlines)
        let definitions: [(labels: [String], kind: QuotaWindowKind)] = [
            (["5h limit", "5-hour limit"], .session),
            (["Weekly limit"], .weekly)
        ]

        var windows: [QuotaWindow] = []
        for definition in definitions {
            guard let index = lines.firstIndex(where: { line in
                definition.labels.contains { line.localizedCaseInsensitiveContains($0) }
            }) else { continue }

            let candidates = Array(lines.dropFirst(index).prefix(5))
            guard let remaining = candidates.compactMap(TextParsing.percentRemaining).first else { continue }
            let resetText = candidates.first(where: { $0.localizedCaseInsensitiveContains("reset") })?
                .trimmingCharacters(in: .whitespacesAndNewlines)
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

        guard !windows.isEmpty else {
            throw ProbeError.invalidResponse("Kimi /usage 没有返回额度窗口")
        }

        let plan = TextParsing.firstMatch(#"(?:plan|membership)\s*[:·]\s*([A-Za-z]+)"#, in: text)
        return ProviderSnapshot(
            provider: .kimi,
            windows: windows,
            balance: nil,
            plan: plan,
            account: nil,
            source: .cli,
            capturedAt: capturedAt,
            errorMessage: nil
        )
    }
}
