import XCTest
@testable import QuotaPeek

@MainActor
final class ProviderFactoryTests: XCTestCase {
    func testBuildsOneProbePerEnabledAccountAndSkipsDisabled() {
        let claude = ProviderAccount(id: UUID(), provider: .claude, label: "工作", credential: .cliHome(path: "/tmp/a"), enabled: true)
        let disabledCodex = ProviderAccount(id: UUID(), provider: .codex, label: "默认", credential: .cliHome(path: ""), enabled: false)
        let grok = ProviderAccount(id: UUID(), provider: .grok, label: "默认", credential: .cookie, enabled: true)

        let pairs = ProviderFactory.make(
            accounts: [claude, disabledCodex, grok],
            executablePaths: (codex: "", claude: "", kimi: ""),
            secret: { _ in nil },
            kimiWebSession: { _ in KimiWebSession.shared }
        )

        XCTAssertEqual(pairs.count, 2, "禁用的账号不应该产出探针")
        XCTAssertEqual(Set(pairs.map(\.account.id)), Set([claude.id, grok.id]))
        XCTAssertTrue(pairs.contains { $0.probe is ClaudeProbe })
        XCTAssertTrue(pairs.contains { $0.probe is GrokProbe })
    }

    func testKimiPicksWebProbeWhenAccountIsLoggedIn() {
        let loggedInSession = KimiWebSession(dataStore: .default(), loginFlagKey: "test.kimi.loggedin.\(UUID())")
        loggedInSession.isLoggedIn = true
        let account = ProviderAccount(id: UUID(), provider: .kimi, label: "默认", credential: .kimi(cliHomePath: ""), enabled: true)

        let pairs = ProviderFactory.make(
            accounts: [account],
            executablePaths: (codex: "", claude: "", kimi: ""),
            secret: { _ in nil },
            kimiWebSession: { _ in loggedInSession }
        )

        XCTAssertEqual(pairs.count, 1)
        XCTAssertTrue(pairs[0].probe is KimiWebProbe)
    }

    func testKimiFallsBackToCLIProbeWhenNotLoggedIn() {
        let loggedOutSession = KimiWebSession(dataStore: .default(), loginFlagKey: "test.kimi.loggedout.\(UUID())")
        let account = ProviderAccount(id: UUID(), provider: .kimi, label: "默认", credential: .kimi(cliHomePath: ""), enabled: true)

        let pairs = ProviderFactory.make(
            accounts: [account],
            executablePaths: (codex: "", claude: "", kimi: ""),
            secret: { _ in nil },
            kimiWebSession: { _ in loggedOutSession }
        )

        XCTAssertEqual(pairs.count, 1)
        XCTAssertTrue(pairs[0].probe is KimiProbe)
    }
}
