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

    func testManagedDirectoryRejectsSymlinkedAccountsRoot() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let realAccounts = temporaryRoot.appendingPathComponent("RealAccounts", isDirectory: true)
        let linkedAccounts = temporaryRoot.appendingPathComponent("Accounts", isDirectory: true)
        try fileManager.createDirectory(at: realAccounts, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkedAccounts, withDestinationURL: realAccounts)

        let id = UUID()
        let storedPath = linkedAccounts.appendingPathComponent(id.uuidString, isDirectory: true).path
        XCTAssertNil(
            ManagedAccountDirectory.removableURL(
                accountID: id,
                storedPath: storedPath,
                accountsDirectory: linkedAccounts
            )
        )
    }

    func testManagedDirectoryRejectsSymlinkedAccountDirectory() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let accounts = temporaryRoot.appendingPathComponent("Accounts", isDirectory: true)
        let outside = temporaryRoot.appendingPathComponent("Outside", isDirectory: true)
        try fileManager.createDirectory(at: accounts, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)

        let id = UUID()
        let linkedAccount = accounts.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createSymbolicLink(at: linkedAccount, withDestinationURL: outside)
        XCTAssertNil(
            ManagedAccountDirectory.removableURL(
                accountID: id,
                storedPath: linkedAccount.path,
                accountsDirectory: accounts
            )
        )
    }
}
