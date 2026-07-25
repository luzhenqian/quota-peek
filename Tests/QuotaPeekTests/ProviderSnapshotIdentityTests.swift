import XCTest
@testable import QuotaPeek

final class ProviderSnapshotIdentityTests: XCTestCase {
    func testSnapshotIDDefaultsToFreshUUIDWhenOmitted() {
        let a = ProviderSnapshot(
            provider: .codex, windows: [], balance: nil, plan: nil,
            account: nil, source: .localRPC, capturedAt: Date(), errorMessage: nil
        )
        let b = ProviderSnapshot(
            provider: .codex, windows: [], balance: nil, plan: nil,
            account: nil, source: .localRPC, capturedAt: Date(), errorMessage: nil
        )
        XCTAssertNotEqual(a.id, b.id, "省略 accountID 时应各自拿到独立随机 UUID")
        XCTAssertEqual(a.id, a.accountID)
    }

    func testFailureCarriesAccountIdentity() {
        let id = UUID()
        let snapshot = ProviderSnapshot.failure(
            accountID: id, provider: .claude, label: "工作",
            message: "需要登录", source: .cli
        )
        XCTAssertEqual(snapshot.accountID, id)
        XCTAssertEqual(snapshot.account, "工作")
        XCTAssertEqual(snapshot.errorMessage, "需要登录")
    }

    func testFailurePreservesPreviousIdentityWhenReusingCache() {
        let id = UUID()
        let previous = ProviderSnapshot(
            accountID: id, provider: .claude, windows: [], balance: nil,
            plan: "MAX", account: "工作", source: .cli, capturedAt: Date(), errorMessage: nil
        )
        let snapshot = ProviderSnapshot.failure(
            provider: .claude, label: "会被忽略", message: "超时", source: .cli, previous: previous
        )
        XCTAssertEqual(snapshot.accountID, id)
        XCTAssertEqual(snapshot.account, "工作", "复用旧快照时应保留原账号标签，不被新传入的 label 覆盖")
    }
}
