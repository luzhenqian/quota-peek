import Foundation

enum TextParsing {
    static func stripANSI(_ text: String) -> String {
        let patterns = [
            "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)",
            "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            "\u{001B}[()][0-2A-Z]",
            "\u{001B}[=>]"
        ]
        let cleaned = patterns.reduce(text) { value, pattern in
            value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return cleaned.replacingOccurrences(of: "\r", with: "\n")
    }

    static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > group,
              let matchRange = Range(match.range(at: group), in: text) else {
            return nil
        }
        return String(text[matchRange])
    }

    static func percentRemaining(from line: String) -> Double? {
        guard let valueText = firstMatch(#"([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*(?:used|left|remaining)"#, in: line),
              let value = Double(valueText) else {
            return nil
        }
        let lower = line.lowercased()
        return lower.contains("used") ? 100 - value : value
    }

    static func relativeResetDate(from text: String, now: Date = Date()) -> Date? {
        let lower = text.lowercased()
        var seconds: TimeInterval = 0

        if let value = firstMatch(#"(\d+)\s*d(?:ays?)?"#, in: lower).flatMap(Double.init) {
            seconds += value * 86_400
        }
        if let value = firstMatch(#"(\d+)\s*h(?:ours?|rs?)?"#, in: lower).flatMap(Double.init) {
            seconds += value * 3_600
        }
        if let value = firstMatch(#"(\d+)\s*m(?:in(?:utes?)?)?"#, in: lower).flatMap(Double.init) {
            seconds += value * 60
        }

        return seconds > 0 ? now.addingTimeInterval(seconds) : nil
    }

    static func resetText(near index: Int, lines: [String], lookAhead: Int = 12) -> String? {
        for line in lines.dropFirst(index).prefix(lookAhead) {
            if line.localizedCaseInsensitiveContains("reset") {
                return line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// 解析 ISO8601 时间戳。各家小数秒位数不一（Kimi 纳秒 9 位、GLM 毫秒 3 位），
    /// `ISO8601DateFormatter` 只接受固定格式，故先剥掉小数秒再按秒级解析。
    static func iso8601Date(from string: String) -> Date? {
        let trimmed = string.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}

extension Date {
    var quotaCountdown: String {
        let remaining = timeIntervalSinceNow
        guard remaining > 0 else { return "即将刷新" }
        let days = Int(remaining / 86_400)
        let hours = Int(remaining.truncatingRemainder(dividingBy: 86_400) / 3_600)
        let minutes = Int(remaining.truncatingRemainder(dividingBy: 3_600) / 60)
        if days > 0 { return "\(days)天 \(hours)小时后刷新" }
        if hours > 0 { return "\(hours)小时 \(minutes)分钟后刷新" }
        return "\(max(1, minutes))分钟后刷新"
    }
}
