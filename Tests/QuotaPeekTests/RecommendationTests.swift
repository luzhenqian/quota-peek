import XCTest
@testable import QuotaPeek

final class RecommendationTests: XCTestCase {
    private func snapshot(accountID: UUID, remaining: Double, hoursUntilReset: Double?) -> ProviderSnapshot {
        let resetsAt = hoursUntilReset.map { Date().addingTimeInterval($0 * 3_600) }
        let window = QuotaWindow(kind: .weekly, remainingPercent: remaining, resetsAt: resetsAt, resetDescription: nil)
        return ProviderSnapshot(
            accountID: accountID, provider: .claude, windows: [window],
            balance: nil, plan: nil, account: nil, source: .cli,
            capturedAt: Date(), errorMessage: nil
        )
    }

    func testPrefersSoonExpiringOverDistantEvenWithLessRemaining() {
        let soon = UUID()
        let distant = UUID()
        let snapshots = [
            snapshot(accountID: distant, remaining: 90, hoursUntilReset: 144),
            snapshot(accountID: soon, remaining: 70, hoursUntilReset: 2)
        ]
        XCTAssertEqual(Recommendation.recommendedAccountID(among: snapshots), soon)
    }

    func testIgnoresAccountsWithNothingLeft() {
        let empty = snapshot(accountID: UUID(), remaining: 0, hoursUntilReset: 1)
        XCTAssertNil(Recommendation.recommendedAccountID(among: [empty]))
    }

    func testUnknownResetTimeUsesNeutralWeight() {
        let id = UUID()
        let window = QuotaWindow(kind: .model("Grok 4"), remainingPercent: 40, resetsAt: nil, resetDescription: "24 小时窗口")
        let snap = ProviderSnapshot(
            accountID: id, provider: .grok, windows: [window], balance: nil,
            plan: nil, account: nil, source: .officialAPI, capturedAt: Date(), errorMessage: nil
        )
        XCTAssertEqual(Recommendation.score(for: snap) ?? -1, 20, accuracy: 0.001) // 40 * 0.5
    }

    func testEmptySnapshotListHasNoRecommendation() {
        XCTAssertNil(Recommendation.recommendedAccountID(among: []))
    }
}
