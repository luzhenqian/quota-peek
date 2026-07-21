import XCTest
@testable import QuotaPeek

final class ProviderParserTests: XCTestCase {
    func testANSICleaningRemovesCSIAndOSCSequences() {
        let bellTerminated = "\u{001B}[2KWeekly limit 23% used\u{001B}[0m\u{001B}]8;;\u{0007}"
        let stringTerminated = "\u{001B}]0;QuotaPeek\u{001B}\\Current session"
        XCTAssertEqual(TextParsing.stripANSI(bellTerminated), "Weekly limit 23% used")
        XCTAssertEqual(TextParsing.stripANSI(stringTerminated), "Current session")
    }

    func testCodexRateLimits() throws {
        let payload = #"{"id":1,"result":{"userAgent":"test"}}"# + "\n" +
            #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":28,"windowDurationMins":300,"resetsAt":1784610000},"secondary":{"usedPercent":59,"windowDurationMins":10080,"resetsAt":1785000000},"credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"},"planType":"plus"}}}"#

        let snapshot = try CodexRateLimitsParser.parse(payload)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 72)
        XCTAssertEqual(snapshot.windows.last?.remainingPercent, 41)
        XCTAssertEqual(snapshot.plan, "PLUS")
        XCTAssertEqual(snapshot.balance?.remaining, Decimal(string: "12.50"))
    }

    func testCodexWeeklyPrimaryAndPerModelLimits() throws {
        let payload = #"{"id":1,"result":{"userAgent":"test"}}"# + "\n" +
            #"{"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":86,"windowDurationMins":10080,"resetsAt":1784955809},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"pro"},"rateLimitsByLimitId":{"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1785206327},"secondary":null,"planType":"pro"},"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":86,"windowDurationMins":10080,"resetsAt":1784955809},"secondary":null,"planType":"pro"}}}}"#

        let snapshot = try CodexRateLimitsParser.parse(payload)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].kind, .weekly)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 14)
        XCTAssertEqual(snapshot.windows[1].kind, .model("GPT-5.3-Codex-Spark"))
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 100)
        XCTAssertEqual(snapshot.plan, "PRO")
    }

    func testKimiMembershipParsesWindowsAndPlan() throws {
        let stats = Data(#"""
        {"ratelimitCode5h":{"enabled":true,"resetTime":"2026-07-21T03:15:20.899140218Z"},
         "ratelimitCode7d":{"ratio":0.2281,"enabled":true,"resetTime":"2026-07-25T00:15:20.899140218Z"},
         "subscriptionBalance":{"id":"x","feature":"FEATURE_OMNI","type":"SUBSCRIPTION","unit":"UNIT_CREDIT",
           "amountUsedRatio":0.5061,"kimiCodeUsedRatio":0.0478,"expireTime":"2026-08-18T00:00:00Z"}}
        """#.utf8)
        let sub = Data(#"""
        {"subscription":{"subscriptionId":"y","goods":{"id":"z","title":"Allegro","durationDays":30,
           "membershipLevel":"LEVEL_ADVANCED"},"status":"SUBSCRIPTION_STATUS_ACTIVE","active":true}}
        """#.utf8)

        let snapshot = try KimiMembershipParser.parse(stats: stats, subscription: sub)

        XCTAssertEqual(snapshot.plan, "Allegro")
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows[0].kind, .session)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 100, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[1].kind, .weekly)
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 77.19, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[2].kind, .monthly)
        XCTAssertEqual(snapshot.windows[2].remainingPercent, 49.39, accuracy: 0.01)
        XCTAssertNotNil(snapshot.windows[1].resetsAt)   // 带小数秒的时间戳能解析
        XCTAssertNotNil(snapshot.windows[2].resetsAt)
    }

    func testKimiMembershipFreeTierNoPlanStillReturnsWindows() throws {
        // 免费/无订阅账号：无套餐信息，但仍应返回额度窗口（plan 为 nil，不抛错）。
        let stats = Data(#"""
        {"ratelimitCode5h":{"ratio":0.1,"resetTime":"2026-07-21T03:15:20.899Z"},
         "ratelimitCode7d":{"ratio":0.3,"resetTime":"2026-07-25T00:15:20.899Z"}}
        """#.utf8)
        let sub = Data(#"{}"#.utf8)
        let snapshot = try KimiMembershipParser.parse(stats: stats, subscription: sub)
        XCTAssertNil(snapshot.plan)
        let session = try XCTUnwrap(snapshot.windows.first(where: { $0.kind == .session }))
        XCTAssertEqual(session.remainingPercent, 90, accuracy: 0.01)
        let weekly = try XCTUnwrap(snapshot.windows.first(where: { $0.kind == .weekly }))
        XCTAssertEqual(weekly.remainingPercent, 70, accuracy: 0.01)
    }

    func testGrokRateLimitsParsesModelWindows() throws {
        let data = Data(#"""
        {"loggedIn":true,"windows":[
          {"label":"Grok 4","remaining":3,"total":7,"windowSizeSeconds":86400},
          {"label":"Grok 4 Heavy","remaining":20,"total":20,"windowSizeSeconds":7200}
        ]}
        """#.utf8)
        let snapshot = try GrokRateLimitParser.parse(data)
        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].kind, .model("Grok 4"))
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 3.0 / 7.0 * 100, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[1].kind, .model("Grok 4 Heavy"))
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 100, accuracy: 0.01)
    }

    func testGrokNotLoggedInThrows() {
        let data = Data(#"{"loggedIn":false,"windows":[]}"#.utf8)
        XCTAssertThrowsError(try GrokRateLimitParser.parse(data))
    }

    func testClaudeUsageWithUsedAndLeftFormats() throws {
        let output = """
        Opus 4.6 · Claude Max
        Current session
        ██████ 27% used
        Resets in 2h 15m
        Current week (all models)
        ███ 64% left
        Resets in 5d 3h
        Current week (Sonnet only)
        80% left
        """

        let snapshot = try ClaudeUsageParser.parse(output)
        XCTAssertEqual(snapshot.plan, "MAX")
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 73)
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 64)
        XCTAssertEqual(snapshot.windows[2].remainingPercent, 80)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
    }

    func testKimiUsage() throws {
        let output = """
        Kimi Code Usage
        Weekly limit  ━━━━━━━━━━━  74% left  (resets in 6d 23h)
        5h limit      ━━━━━━━━━━━  91% left  (resets in 4h 22m)
        """

        let snapshot = try KimiUsageParser.parse(output)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows.first(where: { $0.kind == .weekly })?.remainingPercent, 74)
        XCTAssertEqual(snapshot.windows.first(where: { $0.kind == .session })?.remainingPercent, 91)
    }

    func testGLMQuotaResponse() throws {
        let json = """
        {
          "data": {
            "limits": [
              {"type":"TOKENS_LIMIT","unit":3,"percentage":12.5,"nextResetTime":1784610000000},
              {"type":"TOKENS_LIMIT","unit":6,"percentage":40,"nextResetTime":"2026-07-28T10:00:00Z"},
              {"type":"TIME_LIMIT","unit":5,"percentage":2,"nextResetTime":1787000000000}
            ]
          }
        }
        """

        let snapshot = try GLMQuotaParser.parse(Data(json.utf8))
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows.first(where: { $0.kind == .session })?.remainingPercent, 87.5)
        XCTAssertEqual(snapshot.windows.first(where: { $0.kind == .weekly })?.remainingPercent, 60)
        XCTAssertEqual(snapshot.windows.first(where: { $0.kind == .tools })?.remainingPercent, 98)
    }

    func testRelativeResetParsing() {
        let now = Date(timeIntervalSince1970: 1_000)
        let result = TextParsing.relativeResetDate(from: "resets in 2d 3h 15m", now: now)
        let expected: TimeInterval = 1_000 + 172_800 + 10_800 + 900
        XCTAssertEqual(result?.timeIntervalSince1970, expected)
    }
}
