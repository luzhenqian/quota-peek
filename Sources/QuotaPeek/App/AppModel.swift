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

    var visibleSnapshots: [ProviderSnapshot] {
        enabledProviders.map { provider in
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
        let probes = ProviderFactory.make(preferences: currentPreferences, glmAPIKey: key)

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
        KimiWebSession.isLoggedIn
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
        case .glm: .officialAPI
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
