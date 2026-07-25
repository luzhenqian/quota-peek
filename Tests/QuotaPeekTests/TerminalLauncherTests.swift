import XCTest
@testable import QuotaPeek

final class TerminalLauncherTests: XCTestCase {
    func testAppleScriptEscapesDoubleQuotes() {
        let script = TerminalLauncher.appleScript(for: #"echo "hi""#)
        XCTAssertTrue(script.contains(#"echo \"hi\""#), "命令里的双引号必须转义，否则 AppleScript 字符串会提前截断")
    }

    func testAppleScriptWrapsInTerminalTellBlock() {
        let script = TerminalLauncher.appleScript(for: "echo hi")
        XCTAssertTrue(script.contains("tell application \"Terminal\""))
        XCTAssertTrue(script.contains("do script \"echo hi\""))
    }

    func testLoginCommandPerProvider() {
        XCTAssertEqual(
            TerminalLauncher.loginCommand(provider: .claude, homeDirectory: "/tmp/a"),
            "CLAUDE_CONFIG_DIR='/tmp/a' claude"
        )
        XCTAssertEqual(
            TerminalLauncher.loginCommand(provider: .codex, homeDirectory: "/tmp/b"),
            "CODEX_HOME='/tmp/b' codex login"
        )
        XCTAssertEqual(
            TerminalLauncher.loginCommand(provider: .kimi, homeDirectory: "/tmp/c"),
            "KIMI_CODE_HOME='/tmp/c' kimi login"
        )
    }

    func testLoginCommandShellQuotesDangerousHomeDirectoryCharacters() {
        let homeDirectory = #"/tmp/account name/"quoted"/it's/$(touch /tmp/pwned)/`whoami`"#

        XCTAssertEqual(
            TerminalLauncher.loginCommand(provider: .codex, homeDirectory: homeDirectory),
            #"CODEX_HOME='/tmp/account name/"quoted"/it'"'"'s/$(touch /tmp/pwned)/`whoami`' codex login"#
        )
    }
}
