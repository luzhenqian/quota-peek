import XCTest
@testable import QuotaPeek

final class ProbeEnvironmentTests: XCTestCase {
    func testClaudeEnvironmentClearsAPIKeysAndSetsConfigDirWhenGiven() {
        let overrides = ClaudeProbe.environmentOverrides(homeDirectory: "/tmp/quota-peek-acct")
        XCTAssertEqual(overrides["ANTHROPIC_API_KEY"], "")
        XCTAssertEqual(overrides["ANTHROPIC_AUTH_TOKEN"], "")
        XCTAssertEqual(overrides["ANTHROPIC_BASE_URL"], "")
        XCTAssertEqual(overrides["CLAUDE_CONFIG_DIR"], "/tmp/quota-peek-acct")
    }

    func testClaudeEnvironmentOmitsConfigDirWhenEmpty() {
        let overrides = ClaudeProbe.environmentOverrides(homeDirectory: "")
        XCTAssertNil(overrides["CLAUDE_CONFIG_DIR"], "空串代表沿用 CLI 自己的默认目录，不应该设置成空字符串环境变量")
    }

    func testCodexEnvironmentSetsHomeWhenGiven() {
        XCTAssertEqual(CodexProbe.environmentOverrides(homeDirectory: "/tmp/x")["CODEX_HOME"], "/tmp/x")
        XCTAssertNil(CodexProbe.environmentOverrides(homeDirectory: "")["CODEX_HOME"])
    }

    func testKimiEnvironmentSetsHomeWhenGiven() {
        XCTAssertEqual(KimiProbe.environmentOverrides(homeDirectory: "/tmp/y")["KIMI_CODE_HOME"], "/tmp/y")
        XCTAssertNil(KimiProbe.environmentOverrides(homeDirectory: "")["KIMI_CODE_HOME"])
    }
}
