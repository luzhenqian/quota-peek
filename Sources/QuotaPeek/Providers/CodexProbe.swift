import Foundation

struct CodexProbe: ProviderProbe {
    let provider: ProviderID = .codex
    let source: SnapshotSource = .localRPC

    private let executablePath: String
    private let runner = ProcessRunner()

    init(executablePath: String) {
        self.executablePath = executablePath
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let executable = CommandLocator.locate("codex", explicitPath: executablePath) else {
            throw ProbeError.executableNotFound("Codex CLI")
        }

        let messages = [
            #"{"method":"initialize","id":1,"params":{"clientInfo":{"name":"quota-peek","title":"QuotaPeek","version":"0.1.0"},"capabilities":{"experimentalApi":false}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"method":"account/rateLimits/read","id":2}"#
        ].joined(separator: "\n") + "\n"

        let result = try await runner.run(
            executable: executable,
            arguments: ["-s", "read-only", "-a", "untrusted", "app-server"],
            input: messages,
            timeout: 4,
            closeInput: false
        )

        if result.timedOut && result.text.isEmpty {
            throw ProbeError.timedOut("Codex")
        }
        return try CodexRateLimitsParser.parse(result.text)
    }
}

enum CodexRateLimitsParser {
    static func parse(_ text: String, capturedAt: Date = Date()) throws -> ProviderSnapshot {
        var payload: [String: Any]?
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = object["result"] as? [String: Any],
                  result["rateLimits"] is [String: Any] else {
                continue
            }
            payload = result
        }

        guard let payload, let rateLimits = payload["rateLimits"] as? [String: Any] else {
            if text.localizedCaseInsensitiveContains("not logged in") || text.contains("401") {
                throw ProbeError.authenticationRequired("请先运行 codex login。")
            }
            throw ProbeError.invalidResponse("Codex 未返回 rateLimits")
        }

        var windows: [QuotaWindow] = []
        if let primary = dictionary(rateLimits, keys: ["primary"]) {
            windows.append(window(from: primary, fallbackKind: .session))
        }
        if let secondary = dictionary(rateLimits, keys: ["secondary"]) {
            windows.append(window(from: secondary, fallbackKind: .weekly))
        }

        let aggregateID = string(rateLimits, keys: ["limitId", "limit_id"])
        if let byLimitID = dictionary(payload, keys: ["rateLimitsByLimitId", "rate_limits_by_limit_id"]) {
            let modelEntries = byLimitID.values
                .compactMap { $0 as? [String: Any] }
                .compactMap { entry -> (name: String, primary: [String: Any])? in
                    guard string(entry, keys: ["limitId", "limit_id"]) != aggregateID,
                          let name = string(entry, keys: ["limitName", "limit_name"]),
                          let primary = dictionary(entry, keys: ["primary"]) else { return nil }
                    return (name, primary)
                }
                .sorted { $0.name < $1.name }
            for entry in modelEntries {
                windows.append(window(from: entry.primary, fallbackKind: .model(entry.name), kindOverride: .model(entry.name)))
            }
        }

        guard !windows.isEmpty else {
            throw ProbeError.invalidResponse("Codex 账户没有可用的订阅额度窗口")
        }

        let plan = string(rateLimits, keys: ["planType", "plan_type"])
        var balance: ProviderBalance?
        if let credits = dictionary(rateLimits, keys: ["credits"]),
           (credits["unlimited"] as? Bool) != true,
           let amount = decimal(credits["balance"]) {
            balance = ProviderBalance(remaining: amount, currency: "USD", limit: nil)
        }

        return ProviderSnapshot(
            provider: .codex,
            windows: windows,
            balance: balance,
            plan: plan?.uppercased(),
            account: nil,
            source: .localRPC,
            capturedAt: capturedAt,
            errorMessage: nil
        )
    }

    private static func window(
        from object: [String: Any],
        fallbackKind: QuotaWindowKind,
        kindOverride: QuotaWindowKind? = nil
    ) -> QuotaWindow {
        let kind: QuotaWindowKind
        if let kindOverride {
            kind = kindOverride
        } else if let minutes = double(object, keys: ["windowDurationMins", "window_duration_mins"]) {
            kind = windowKind(forDurationMinutes: minutes)
        } else {
            kind = fallbackKind
        }
        let used = double(object, keys: ["usedPercent", "used_percent"]) ?? 0
        let resetSeconds = double(object, keys: ["resetsAt", "resets_at"])
        let reset = resetSeconds.map { Date(timeIntervalSince1970: $0) }
        return QuotaWindow(
            kind: kind,
            remainingPercent: 100 - used,
            resetsAt: reset,
            resetDescription: reset?.quotaCountdown
        )
    }

    /// Codex 只回传窗口时长（分钟），额度档位需按时长归类。
    private static func windowKind(forDurationMinutes minutes: Double) -> QuotaWindowKind {
        switch minutes {
        case 240...360: return .session
        case 9_000...11_520: return .weekly
        case 40_320...44_640: return .monthly
        default:
            if minutes < 2_880 {
                return .model("\(Int((minutes / 60).rounded())) 小时")
            }
            return .model("\(Int((minutes / 1_440).rounded())) 天")
        }
    }

    private static func dictionary(_ object: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = object[key] as? [String: Any] { return value }
        }
        return nil
    }

    private static func string(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String { return value }
        }
        return nil
    }

    private static func double(_ object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key] as? Double { return value }
            if let value = object[key] as? Int { return Double(value) }
        }
        return nil
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        if let value = value as? String { return Decimal(string: value) }
        if let value = value as? Double { return Decimal(value) }
        if let value = value as? Int { return Decimal(value) }
        return nil
    }
}
