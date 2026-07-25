import Foundation
import OSLog
import UserNotifications
import WebKit

/// Determines whether an old fixed Keychain entry should seed an account-scoped entry.
enum KeychainMigration {
    static func shouldMigrate(legacyValue: String?, newValue: String?) -> Bool {
        legacyValue?.isEmpty == false && newValue?.isEmpty != false
    }
}

/// Keeps recursive deletion constrained to the directory QuotaPeek created for this UUID.
enum ManagedAccountDirectory {
    static func removableURL(
        accountID: UUID,
        storedPath: String,
        accountsDirectory: URL
    ) -> URL? {
        guard !storedPath.isEmpty else { return nil }
        let expected = accountsDirectory
            .appendingPathComponent(accountID.uuidString, isDirectory: true)
            .standardizedFileURL
        let stored = URL(fileURLWithPath: storedPath, isDirectory: true).standardizedFileURL
        guard stored == expected else { return nil }

        // `removeItem` recursively follows the directory path. Reject both a symlinked
        // Accounts root and a symlink at/under the account path rather than allowing the
        // preference to redirect deletion outside QuotaPeek's managed tree.
        let standardizedRoot = accountsDirectory.standardizedFileURL
        guard standardizedRoot.resolvingSymlinksInPath() == standardizedRoot,
              stored.resolvingSymlinksInPath() == stored else {
            return nil
        }
        return expected
    }
}

/// Transfers an object into asynchronous cleanup without leaving an immutable captured
/// parameter that keeps the object alive after the cleanup has explicitly released it.
final class ClearableReferenceHolder<Reference: AnyObject> {
    private var reference: Reference?

    init(_ reference: Reference?) {
        self.reference = reference
    }

    func take() -> Reference? {
        defer { reference = nil }
        return reference
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var snapshots: [ProviderSnapshot]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshAt: Date?
    @Published var preferences: AppPreferences {
        didSet {
            PreferencesStore.save(preferences)
            scheduleRefresh()
            if preferences.floatingPanelEnabled {
                FloatingPanelManager.shared.show(model: self)
            } else {
                FloatingPanelManager.shared.hide()
            }
        }
    }

    private var refreshLoop: Task<Void, Never>?
    private var started = false
    private static let accountsDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("QuotaPeek", isDirectory: true)
        .appendingPathComponent("Accounts", isDirectory: true)
    private static let keychainMigrationFlag = "QuotaPeek.migratedAccountKeychain.v1"
    private static let logger = Logger(
        subsystem: "com.quotapeek.app",
        category: "account-cleanup"
    )
    private var kimiWebSessions: [UUID: KimiWebSession] = [:]

    private init() {
        preferences = PreferencesStore.load()
        snapshots = SnapshotStore.load()
    }

    deinit {
        refreshLoop?.cancel()
    }

    var executablePaths: (codex: String, claude: String, kimi: String) {
        (preferences.codexExecutable, preferences.claudeExecutable, preferences.kimiExecutable)
    }

    private var baseSnapshots: [ProviderSnapshot] {
        preferences.accounts.filter(\.enabled).map { account -> ProviderSnapshot in
            if let snapshot = snapshots.first(where: { $0.accountID == account.id }) {
                return snapshot
            }
            return .failure(
                accountID: account.id,
                provider: account.provider,
                label: account.label,
                message: isRefreshing ? "正在查询…" : "等待首次查询",
                source: defaultSource(for: account.provider)
            )
        }
    }

    var recommendedAccountID: UUID? {
        Recommendation.recommendedAccountID(among: baseSnapshots)
    }

    var visibleSnapshots: [ProviderSnapshot] {
        let base = baseSnapshots
        guard let recommended = recommendedAccountID,
              let index = base.firstIndex(where: { $0.accountID == recommended }), index != 0 else {
            return base
        }
        var reordered = base
        reordered.insert(reordered.remove(at: index), at: 0)
        return reordered
    }

    var overallRemainingPercent: Double? {
        visibleSnapshots.compactMap(\.minimumRemainingPercent).min()
    }

    var menuBarSymbol: String {
        guard let remaining = overallRemainingPercent else { return "gauge.with.dots.needle.0percent" }
        if remaining <= 10 { return "gauge.with.dots.needle.100percent" }
        if remaining <= 25 { return "gauge.with.dots.needle.67percent" }
        return "gauge.with.dots.needle.33percent"
    }

    func start() {
        guard !started else { return }
        started = true
        migrateLegacyKeychainIfNeeded()
        if preferences.notificationsEnabled {
            Task { await NotificationManager.requestAuthorization() }
        }
        if preferences.floatingPanelEnabled {
            FloatingPanelManager.shared.show(model: self)
        }
        scheduleRefresh(immediate: true)
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let currentPreferences = preferences
        let pairs = ProviderFactory.make(
            accounts: currentPreferences.accounts,
            executablePaths: executablePaths,
            secret: { [weak self] account in self?.secretOverride(for: account) },
            kimiWebSession: { [weak self] account in
                self?.kimiWebSession(for: account) ?? .shared
            }
        )

        let cliPairs = pairs.filter { $0.probe.source == .cli }
        let independentPairs = pairs.filter { $0.probe.source != .cli }
        let results = await withTaskGroup(of: [ProviderResult].self, returning: [ProviderResult].self) { group in
            struct HomeDirectoryGroupKey: Hashable {
                let provider: ProviderID
                let homeDirectory: String
            }
            let cliGroups = Dictionary(grouping: cliPairs) { pair in
                HomeDirectoryGroupKey(
                    provider: pair.account.provider,
                    homeDirectory: pair.account.credential.cliHomeDirectory ?? ""
                )
            }
            for (_, groupPairs) in cliGroups {
                group.addTask {
                    var batch: [ProviderResult] = []
                    for pair in groupPairs {
                        batch.append(await Self.fetchCLIResult(from: pair.probe, account: pair.account))
                    }
                    return batch
                }
            }
            for pair in independentPairs {
                group.addTask { [await Self.fetchResult(from: pair.probe, account: pair.account)] }
            }

            var collected: [ProviderResult] = []
            for await batch in group { collected.append(contentsOf: batch) }
            return collected
        }

        // Refresh may take long enough for account settings to change while probes are in flight.
        // Reconcile against the live preferences so a removed/disabled account cannot be
        // resurrected in SnapshotStore, and a renamed account uses its current identity.
        let accountsByID = Dictionary(uniqueKeysWithValues: preferences.accounts.map { ($0.id, $0) })
        var updated = snapshots.filter { snapshot in
            guard let account = accountsByID[snapshot.accountID] else { return false }
            return !account.enabled
        }
        for result in results {
            guard let account = accountsByID[result.account.id], account.enabled else { continue }
            if var snapshot = result.snapshot {
                snapshot.accountID = account.id
                snapshot.provider = account.provider
                snapshot.account = account.label
                updated.append(snapshot)
                if preferences.notificationsEnabled {
                    NotificationManager.notifyIfNeeded(
                        snapshot: snapshot,
                        threshold: Double(preferences.notificationThreshold)
                    )
                }
            } else {
                let previous = snapshots.first(where: { $0.accountID == account.id })
                var failure = ProviderSnapshot.failure(
                    accountID: account.id,
                    provider: account.provider,
                    label: account.label,
                    message: result.errorMessage ?? "未知错误",
                    source: result.source,
                    previous: previous
                )
                // `failure(previous:)` 保留上一份数据；账号身份仍必须以本轮的账号配置为准。
                failure.accountID = account.id
                failure.provider = account.provider
                failure.account = account.label
                updated.append(failure)
            }
        }

        snapshots = updated
        lastRefreshAt = Date()
        SnapshotStore.save(snapshots)
    }

    func addCLIAccount(provider: ProviderID, label: String) throws {
        guard provider == .codex || provider == .claude || provider == .kimi else {
            throw ProbeError.requestFailed("该服务商不支持 CLI 账号。")
        }

        let id = UUID()
        let directory = Self.accountsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let credential: AccountCredential = provider == .kimi
            ? .kimi(cliHomePath: directory.path)
            : .cliHome(path: directory.path)
        var updated = preferences
        updated.accounts.append(
            ProviderAccount(id: id, provider: provider, label: label, credential: credential, enabled: true)
        )
        preferences = updated
        TerminalLauncher.run(
            command: TerminalLauncher.loginCommand(provider: provider, homeDirectory: directory.path)
        )
    }

    func addCredentialAccount(
        provider: ProviderID,
        label: String,
        baseURL: String = "https://open.bigmodel.cn"
    ) {
        guard provider == .glm || provider == .grok else { return }
        let credential: AccountCredential = provider == .glm ? .apiKey(baseURL: baseURL) : .cookie
        var updated = preferences
        updated.accounts.append(
            ProviderAccount(
                id: UUID(),
                provider: provider,
                label: label,
                credential: credential,
                enabled: true
            )
        )
        preferences = updated
    }

    func addKimiWebAccount(label: String) {
        var updated = preferences
        updated.accounts.append(
            ProviderAccount(
                id: UUID(),
                provider: .kimi,
                label: label,
                credential: .kimi(cliHomePath: ""),
                enabled: true
            )
        )
        preferences = updated
    }

    func renameAccount(id: UUID, label: String) {
        guard let index = preferences.accounts.firstIndex(where: { $0.id == id }) else { return }
        var updated = preferences
        updated.accounts[index].label = label
        preferences = updated
    }

    func removeAccount(id: UUID) {
        guard let account = preferences.accounts.first(where: { $0.id == id }) else { return }

        if let path = account.credential.cliHomeDirectory,
           let directory = ManagedAccountDirectory.removableURL(
               accountID: id,
               storedPath: path,
               accountsDirectory: Self.accountsDirectory
           ) {
            try? FileManager.default.removeItem(at: directory)
        }
        if let key = account.keychainKey {
            try? SecretStore.save("", account: key)
        }
        if account.provider == .kimi {
            let isLegacyDefault = id == ProviderAccount.legacyDefaultID(for: .kimi)
            let flagKey = isLegacyDefault
                ? KimiWebSession.legacyLoggedInDefaultsKey
                : "QuotaPeek.kimiWebLoggedIn.\(id.uuidString)"
            UserDefaults.standard.removeObject(forKey: flagKey)
            if isLegacyDefault {
                // The migrated account intentionally keeps using the historical default store.
                // It has no removable identifier, so clear only Kimi records through its session.
                let legacySession = kimiWebSessions.removeValue(forKey: id)
                    ?? kimiWebSession(for: account)
                kimiWebSessions[id] = nil
                Task {
                    await legacySession.logout()
                }
            } else {
                let sessionHolder = ClearableReferenceHolder(
                    kimiWebSessions.removeValue(forKey: id)
                )
                Task {
                    await Self.removeKimiDataStore(
                        identifier: id,
                        loginFlagKey: flagKey,
                        sessionHolder: sessionHolder
                    )
                }
            }
        }

        var updated = preferences
        updated.accounts.removeAll { $0.id == id }
        preferences = updated
        snapshots.removeAll { $0.accountID == id }
        SnapshotStore.save(snapshots)
    }

    private static func removeKimiDataStore(
        identifier: UUID,
        loginFlagKey: String,
        sessionHolder: ClearableReferenceHolder<KimiWebSession>
    ) async {
        // Clear Kimi records first, then release AppModel's last known session/store owner.
        // An in-flight refresh may still retain the probe temporarily, so identifier removal
        // uses bounded backoff instead of permanently leaking the store after one busy error.
        var session: KimiWebSession? = sessionHolder.take() ?? KimiWebSession(
            dataStore: WKWebsiteDataStore(forIdentifier: identifier),
            loginFlagKey: loginFlagKey
        )
        await session?.logout()
        session = nil
        UserDefaults.standard.removeObject(forKey: loginFlagKey)

        let retryDelays: [Duration] = [
            .zero,
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
            .seconds(8)
        ]
        var finalError: Error?
        for delay in retryDelays {
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                UserDefaults.standard.removeObject(forKey: loginFlagKey)
                return
            } catch {
                finalError = error
            }
        }

        if let finalError {
            UserDefaults.standard.removeObject(forKey: loginFlagKey)
            logger.error(
                "Failed to remove Kimi data store \(identifier.uuidString, privacy: .public) after retries: \(finalError.localizedDescription, privacy: .public)"
            )
        }
    }

    func saveSecret(_ value: String, for account: ProviderAccount) throws {
        guard let key = account.keychainKey else { return }
        try SecretStore.save(
            value.trimmingCharacters(in: .whitespacesAndNewlines),
            account: key
        )
    }

    func hasSecret(for account: ProviderAccount) -> Bool {
        guard let key = account.keychainKey else { return false }
        let accountValue = SecretStore.read(account: key)
        if account.provider == .glm {
            return GLMCredentialResolver.resolve(explicit: accountValue)?.isEmpty == false
        }
        return accountValue?.isEmpty == false
    }

    private func secretOverride(for account: ProviderAccount) -> String? {
        guard let key = account.keychainKey else { return nil }
        return SecretStore.read(account: key)
    }

    func kimiWebSession(for account: ProviderAccount) -> KimiWebSession {
        guard account.provider == .kimi else { return .shared }
        if let existing = kimiWebSessions[account.id] { return existing }

        let isLegacyDefault = account.id == ProviderAccount.legacyDefaultID(for: .kimi)
        let dataStore = isLegacyDefault
            ? WKWebsiteDataStore.default()
            : WKWebsiteDataStore(forIdentifier: account.id)
        let flagKey = isLegacyDefault
            ? KimiWebSession.legacyLoggedInDefaultsKey
            : "QuotaPeek.kimiWebLoggedIn.\(account.id.uuidString)"
        let session = KimiWebSession(dataStore: dataStore, loginFlagKey: flagKey)
        kimiWebSessions[account.id] = session
        return session
    }

    func kimiWebIsLoggedIn(accountID: UUID) -> Bool {
        guard let account = preferences.accounts.first(where: {
            $0.id == accountID && $0.provider == .kimi
        }) else { return false }
        return kimiWebSession(for: account).isLoggedIn
    }

    func kimiLogin(accountID: UUID) async {
        guard let account = preferences.accounts.first(where: {
            $0.id == accountID && $0.provider == .kimi
        }) else { return }
        await kimiWebSession(for: account).presentLogin()
        objectWillChange.send()
        await refreshAll()
    }

    func kimiLogout(accountID: UUID) async {
        guard let account = preferences.accounts.first(where: {
            $0.id == accountID && $0.provider == .kimi
        }) else { return }
        await kimiWebSession(for: account).logout()
        objectWillChange.send()
        await refreshAll()
    }

    // Task 11 replaces the legacy settings sections with account rows. Keep these adapters
    // until then so the staged implementation continues to build and the migrated default
    // account retains its original Kimi data store/login flag.
    func saveGLMAPIKey(_ value: String) throws {
        guard let account = legacyDefaultAccount(for: .glm) else { return }
        try saveSecret(value, for: account)
    }

    func hasGLMAPIKey() -> Bool {
        guard let account = legacyDefaultAccount(for: .glm) else {
            return GLMCredentialResolver.resolve(explicit: nil)?.isEmpty == false
        }
        return hasSecret(for: account)
    }

    func saveGrokCookie(_ value: String) throws {
        guard let account = legacyDefaultAccount(for: .grok) else { return }
        try saveSecret(value, for: account)
    }

    func hasGrokCookie() -> Bool {
        guard let account = legacyDefaultAccount(for: .grok) else { return false }
        return hasSecret(for: account)
    }

    func kimiWebIsLoggedIn() -> Bool {
        guard let account = legacyDefaultAccount(for: .kimi) else {
            return KimiWebSession.shared.isLoggedIn
        }
        return kimiWebSession(for: account).isLoggedIn
    }

    func kimiLogin() async {
        guard let account = legacyDefaultAccount(for: .kimi) else { return }
        await kimiLogin(accountID: account.id)
    }

    func kimiLogout() async {
        guard let account = legacyDefaultAccount(for: .kimi) else { return }
        await kimiLogout(accountID: account.id)
    }

    private func legacyDefaultAccount(for provider: ProviderID) -> ProviderAccount? {
        let id = ProviderAccount.legacyDefaultID(for: provider)
        return preferences.accounts.first { $0.id == id && $0.provider == provider }
    }

    private func migrateLegacyKeychainIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.keychainMigrationFlag) else { return }

        for (provider, legacyKey) in [(ProviderID.glm, "glm-api-key"), (.grok, "grok-cookie")] {
            guard let account = preferences.accounts.first(where: {
                $0.id == ProviderAccount.legacyDefaultID(for: provider)
            }), let newKey = account.keychainKey else {
                continue
            }
            let legacyValue = SecretStore.read(account: legacyKey)
            let newValue = SecretStore.read(account: newKey)
            if KeychainMigration.shouldMigrate(legacyValue: legacyValue, newValue: newValue),
               let legacyValue {
                try? SecretStore.save(legacyValue, account: newKey)
            }
        }
        UserDefaults.standard.set(true, forKey: Self.keychainMigrationFlag)
    }

    func toggleFloatingPanel() {
        if FloatingPanelManager.shared.isVisible {
            FloatingPanelManager.shared.hide()
            preferences.floatingPanelEnabled = false
        } else {
            FloatingPanelManager.shared.show(model: self)
            preferences.floatingPanelEnabled = true
        }
    }

    private func scheduleRefresh(immediate: Bool = false) {
        guard started else { return }
        refreshLoop?.cancel()
        let interval = max(1, preferences.refreshIntervalMinutes)
        refreshLoop = Task { [weak self] in
            if immediate { await self?.refreshAll() }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval * 60))
                } catch {
                    return
                }
                await self?.refreshAll()
            }
        }
    }

    private func defaultSource(for provider: ProviderID) -> SnapshotSource {
        switch provider {
        case .codex: .localRPC
        case .claude, .kimi: .cli
        case .glm, .grok: .officialAPI
        }
    }

    nonisolated private static func fetchResult(
        from probe: any ProviderProbe,
        account: ProviderAccount
    ) async -> ProviderResult {
        do {
            return ProviderResult(
                account: account,
                snapshot: try await probe.fetch(),
                errorMessage: nil,
                source: probe.source
            )
        } catch {
            return ProviderResult(
                account: account,
                snapshot: nil,
                errorMessage: error.localizedDescription,
                source: probe.source
            )
        }
    }

    nonisolated private static func fetchCLIResult(
        from probe: any ProviderProbe,
        account: ProviderAccount
    ) async -> ProviderResult {
        let first = await fetchResult(from: probe, account: account)
        guard first.snapshot == nil else { return first }
        try? await Task.sleep(for: .seconds(1))
        return await fetchResult(from: probe, account: account)
    }
}

enum NotificationManager {
    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    static func notifyIfNeeded(snapshot: ProviderSnapshot, threshold: Double) {
        guard let remaining = snapshot.minimumRemainingPercent, remaining <= threshold else { return }
        let band = remaining <= 5 ? "critical" : "warning"
        let resetKey = snapshot.windows.compactMap(\.resetsAt).map { String(Int($0.timeIntervalSince1970)) }.joined()
        let key = "QuotaPeek.notice.\(snapshot.accountID.uuidString).\(band).\(resetKey)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(snapshot.provider.shortName) 额度提醒"
        content.body = "当前最紧张的额度仅剩 \(Int(remaining.rounded()))%。"
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: key, content: content, trigger: nil)
        )
        UserDefaults.standard.set(true, forKey: key)
    }
}
