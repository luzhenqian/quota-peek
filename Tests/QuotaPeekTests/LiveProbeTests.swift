import XCTest
@testable import QuotaPeek

final class LiveProbeTests: XCTestCase {
    func testInstalledCLIProbesWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["QUOTAPEEK_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set QUOTAPEEK_LIVE_TESTS=1 to query locally installed CLIs.")
        }

        let environment = ProcessInfo.processInfo.environment
        let allProbes: [any ProviderProbe] = [
            CodexProbe(executablePath: environment["QUOTAPEEK_CODEX_PATH"] ?? ""),
            ClaudeProbe(executablePath: environment["QUOTAPEEK_CLAUDE_PATH"] ?? ""),
            KimiProbe(executablePath: environment["QUOTAPEEK_KIMI_PATH"] ?? "")
        ]
        let requestedProvider = environment["QUOTAPEEK_LIVE_PROVIDER"]
        let probes = allProbes.filter { requestedProvider == nil || $0.provider.rawValue == requestedProvider }

        for probe in probes {
            do {
                let snapshot = try await probe.fetch()
                XCTAssertFalse(snapshot.windows.isEmpty, "\(probe.provider.rawValue) should return a quota window")
            } catch {
                XCTFail("\(probe.provider.rawValue): \(error.localizedDescription)")
            }
        }
    }
}
