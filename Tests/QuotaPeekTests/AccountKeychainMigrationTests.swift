import XCTest
@testable import QuotaPeek

final class AccountKeychainMigrationTests: XCTestCase {
    func testMigratesWhenLegacyHasValueAndNewDoesNot() {
        XCTAssertTrue(KeychainMigration.shouldMigrate(legacyValue: "sk-old", newValue: nil))
        XCTAssertTrue(KeychainMigration.shouldMigrate(legacyValue: "sk-old", newValue: ""))
    }

    func testDoesNotMigrateWhenNewAlreadyHasValue() {
        XCTAssertFalse(KeychainMigration.shouldMigrate(legacyValue: "sk-old", newValue: "sk-new"))
    }

    func testDoesNotMigrateWhenLegacyIsEmpty() {
        XCTAssertFalse(KeychainMigration.shouldMigrate(legacyValue: nil, newValue: nil))
        XCTAssertFalse(KeychainMigration.shouldMigrate(legacyValue: "", newValue: nil))
    }

    func testManagedDirectoryAcceptsOnlyExactAccountDirectory() {
        let root = URL(fileURLWithPath: "/tmp/QuotaPeek/Accounts", isDirectory: true)
        let id = UUID(uuidString: "D27FFB1A-28E4-4EFC-972C-F4E95ABAD908")!
        let expected = root.appendingPathComponent(id.uuidString, isDirectory: true)

        XCTAssertEqual(
            ManagedAccountDirectory.removableURL(
                accountID: id,
                storedPath: expected.path,
                accountsDirectory: root
            ),
            expected.standardizedFileURL
        )
    }

    func testManagedDirectoryRejectsEmptyExternalAndTraversalPaths() {
        let root = URL(fileURLWithPath: "/tmp/QuotaPeek/Accounts", isDirectory: true)
        let id = UUID(uuidString: "D27FFB1A-28E4-4EFC-972C-F4E95ABAD908")!

        for path in [
            "",
            "/tmp",
            root.appendingPathComponent("some-other-account").path,
            root.appendingPathComponent(id.uuidString).appendingPathComponent("..").path
        ] {
            XCTAssertNil(
                ManagedAccountDirectory.removableURL(
                    accountID: id,
                    storedPath: path,
                    accountsDirectory: root
                )
            )
        }
    }
}
