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

    var enabledProviders: [ProviderID] {
        ProviderID.allCases.filter(preferences.isEnabled)
    }

    private var baseSnapshots: [ProviderSnapshot] {
        enabledProviders.map { provider -> ProviderSnapshot in
            if let snapshot = snapshots.first(where: { $0.provider == provider }) {
                return snapshot
            }
            return .failure(
                provider: provider,
                message: isRefreshing ? "正在查询…" : "等待首次查询",
                source: defaultSource(for: provider)
            )
        }
    }

    /// 各家额度到期不结转，未用完就浪费。优先推荐"头号指标"（月>周>...）里
    /// 剩余多、又快要刷新的那家 —— 剩余多说明有空间可用，快刷新说明再不用就要被清零，两者都高的最该优先用。
    /// 剩余量与刷新紧迫度（24 小时为半衰尺度，一天内权重接近 1，快到一周时权重降到 0.15 左右）相乘得分。
    var recommendedProvider: ProviderID? {
        Self.recommendedProvider(among: baseSnapshots)
    }

    var visibleSnapshots: [ProviderSnapshot] {
        let base = baseSnapshots
        guard let recommended = recommendedProvider,
              let index = base.firstIndex(where: { $0.provider == recommended }), index != 0 else {
            return base
        }
        var reordered = base
        reordered.insert(reordered.remove(at: index), at: 0)
        return reordered
    }

    private static func recommendedProvider(among snapshots: [ProviderSnapshot]) -> ProviderID? {
        let now = Date()
        let scored = snapshots.compactMap { snapshot -> (ProviderID, Double)? in
            recommendationScore(for: snapshot, now: now).map { (snapshot.provider, $0) }
        }
        return scored.max(by: { $0.1 < $1.1 })?.0
    }

    private static func recommendationScore(for snapshot: ProviderSnapshot, now: Date) -> Double? {
        guard let window = snapshot.headlineWindow, window.remainingPercent > 0 else { return nil }
        guard let resetsAt = window.resetsAt else {
            // 不知道具体刷新时间（如 Grok 的滚动窗口），按中性紧迫度处理，既不抢跑也不被埋没。
            return window.remainingPercent * 0.5
        }
        let hoursUntilReset = max(0, resetsAt.timeIntervalSince(now) / 3_600)
        let urgency = 24 / (24 + hoursUntilReset)
        return window.remainingPercent * urgency
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
        let key = SecretStore.read(account: "glm-api-key")
        let grokCookie = SecretStore.read(account: "grok-cookie")
        let probes = ProviderFactory.make(preferences: currentPreferences, glmAPIKey: key, grokCookie: grokCookie)

        let cliProbes = probes.filter { $0.source == .cli }
        let independentProbes = probes.filter { $0.source != .cli }
        let results = await withTaskGroup(of: [ProviderResult].self, returning: [ProviderResult].self) { group in
            if !cliProbes.isEmpty {
                group.addTask {
                    var batch: [ProviderResult] = []
                    for probe in cliProbes {
                        batch.append(await Self.fetchCLIResult(from: probe))
                    }
                    return batch
                }
            }
            for probe in independentProbes {
                group.addTask { [await Self.fetchResult(from: probe)] }
            }

            var collected: [ProviderResult] = []
            for await batch in group { collected.append(contentsOf: batch) }
            return collected
        }

        var updated = snapshots.filter { !currentPreferences.isEnabled($0.provider) }
        for result in results {
            if let snapshot = result.snapshot {
                updated.append(snapshot)
                if preferences.notificationsEnabled {
                    NotificationManager.notifyIfNeeded(
                        snapshot: snapshot,
                        threshold: Double(preferences.notificationThreshold)
                    )
                }
            } else {
                let previous = snapshots.first(where: { $0.provider == result.provider })
                updated.append(.failure(
                    provider: result.provider,
                    message: result.errorMessage ?? "未知错误",
                    source: result.source,
                    previous: previous
                ))
            }
        }

        snapshots = updated.sorted { lhs, rhs in
            ProviderID.allCases.firstIndex(of: lhs.provider)! < ProviderID.allCases.firstIndex(of: rhs.provider)!
        }
        lastRefreshAt = Date()
        SnapshotStore.save(snapshots)
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

    nonisolated private static func fetchResult(from probe: any ProviderProbe) async -> ProviderResult {
        do {
            return ProviderResult(
                provider: probe.provider,
                snapshot: try await probe.fetch(),
                errorMessage: nil,
                source: probe.source
            )
        } catch {
            return ProviderResult(
                provider: probe.provider,
                snapshot: nil,
                errorMessage: error.localizedDescription,
                source: probe.source
            )
        }
    }

    nonisolated private static func fetchCLIResult(from probe: any ProviderProbe) async -> ProviderResult {
        let first = await fetchResult(from: probe)
        guard first.snapshot == nil else { return first }
        try? await Task.sleep(for: .seconds(1))
        return await fetchResult(from: probe)
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
        let key = "QuotaPeek.notice.\(snapshot.provider.rawValue).\(band).\(resetKey)"
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
