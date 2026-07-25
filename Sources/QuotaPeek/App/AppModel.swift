import Foundation
import UserNotifications

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
            secret: { [weak self] account in
                guard let key = account.keychainKey else { return nil }
                return self?.secretOverride(for: account) ?? SecretStore.read(account: key)
            },
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

        let accountsByID = Dictionary(uniqueKeysWithValues: currentPreferences.accounts.map { ($0.id, $0) })
        var updated = snapshots.filter { snapshot in
            guard let account = accountsByID[snapshot.accountID] else { return false }
            return !account.enabled
        }
        for result in results {
            if var snapshot = result.snapshot {
                snapshot.accountID = result.account.id
                snapshot.account = result.account.label
                updated.append(snapshot)
                if preferences.notificationsEnabled {
                    NotificationManager.notifyIfNeeded(
                        snapshot: snapshot,
                        threshold: Double(preferences.notificationThreshold)
                    )
                }
            } else {
                let previous = snapshots.first(where: { $0.accountID == result.account.id })
                var failure = ProviderSnapshot.failure(
                    accountID: result.account.id,
                    provider: result.account.provider,
                    label: result.account.label,
                    message: result.errorMessage ?? "未知错误",
                    source: result.source,
                    previous: previous
                )
                // `failure(previous:)` 保留上一份数据；账号身份仍必须以本轮的账号配置为准。
                failure.accountID = result.account.id
                failure.provider = result.account.provider
                failure.account = result.account.label
                updated.append(failure)
            }
        }

        snapshots = updated
        lastRefreshAt = Date()
        SnapshotStore.save(snapshots)
    }

    private func secretOverride(for account: ProviderAccount) -> String? { nil }

    private func kimiWebSession(for account: ProviderAccount) -> KimiWebSession {
        if account.provider != .kimi { return .shared }
        return .shared
    }

    func saveGLMAPIKey(_ value: String) throws {
        try SecretStore.save(value.trimmingCharacters(in: .whitespacesAndNewlines), account: "glm-api-key")
    }

    func hasGLMAPIKey() -> Bool {
        SecretStore.read(account: "glm-api-key")?.isEmpty == false
            || GLMCredentialResolver.resolve(explicit: nil)?.isEmpty == false
    }

    func kimiWebIsLoggedIn() -> Bool {
        KimiWebSession.shared.isLoggedIn
    }

    func kimiLogin() async {
        await KimiWebSession.shared.presentLogin()
        objectWillChange.send()
        await refreshAll()
    }

    func kimiLogout() async {
        await KimiWebSession.shared.logout()
        objectWillChange.send()
        await refreshAll()
    }

    func saveGrokCookie(_ value: String) throws {
        try SecretStore.save(value.trimmingCharacters(in: .whitespacesAndNewlines), account: "grok-cookie")
    }

    func hasGrokCookie() -> Bool {
        SecretStore.read(account: "grok-cookie")?.isEmpty == false
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
