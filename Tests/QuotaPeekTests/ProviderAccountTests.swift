import XCTest
@testable import QuotaPeek

final class ProviderAccountTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let account = ProviderAccount(
            id: UUID(), provider: .claude, label: "工作",
            credential: .cliHome(path: "/tmp/foo"), enabled: true
        )
        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(ProviderAccount.self, from: data)
        XCTAssertEqual(decoded, account)
    }

    func testLegacyDefaultIDsAreStableAndDistinct() {
        let ids = ProviderID.allCases.map(ProviderAccount.legacyDefaultID(for:))
        XCTAssertEqual(Set(ids).count, ProviderID.allCases.count, "每个 Provider 的迁移 UUID 必须互不相同")
        XCTAssertEqual(
            ProviderAccount.legacyDefaultID(for: .claude),
            ProviderAccount.legacyDefaultID(for: .claude),
            "同一 Provider 多次调用必须返回同一个 UUID（幂等）"
        )
    }

    func testKeychainKeyOnlyForSecretBasedCredentials() {
        let glm = ProviderAccount(
            id: UUID(), provider: .glm, label: "默认",
            credential: .apiKey(baseURL: "https://open.bigmodel.cn"), enabled: true
        )
        XCTAssertEqual(glm.keychainKey, "glm-api-key-\(glm.id.uuidString)")

        let claude = ProviderAccount(
            id: UUID(), provider: .claude, label: "默认",
            credential: .cliHome(path: ""), enabled: true
        )
        XCTAssertNil(claude.keychainKey)
    }

    func testCLIHomeDirectoryExtraction() {
        XCTAssertEqual(AccountCredential.cliHome(path: "/tmp/a").cliHomeDirectory, "/tmp/a")
        XCTAssertEqual(AccountCredential.kimi(cliHomePath: "/tmp/b").cliHomeDirectory, "/tmp/b")
        XCTAssertNil(AccountCredential.apiKey(baseURL: "x").cliHomeDirectory)
        XCTAssertNil(AccountCredential.cookie.cliHomeDirectory)
    }
}
