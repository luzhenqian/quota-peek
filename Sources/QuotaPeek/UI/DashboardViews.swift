import AppKit
import SwiftUI

struct MenuDashboardView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            DashboardHeader(model: model, compact: false)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider().opacity(0.55)

            ScrollView {
                ProviderCards(model: model)
                    .padding(14)
            }

            Divider().opacity(0.55)

            HStack {
                Button {
                    model.toggleFloatingPanel()
                } label: {
                    Label(
                        FloatingPanelManager.shared.isVisible ? "隐藏悬浮窗" : "显示悬浮窗",
                        systemImage: "macwindow.on.rectangle"
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                Button("设置") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)
                Divider().frame(height: 14)
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .frame(width: 420, height: 600)
        .background(.ultraThinMaterial)
    }
}

struct FloatingDashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DashboardHeader(model: model, compact: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

            ScrollView {
                ProviderCards(model: model)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct DashboardHeader: View {
    @ObservedObject var model: AppModel
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.indigo, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: compact ? 13 : 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: compact ? 26 : 40, height: compact ? 26 : 40)

            if compact {
                HStack(spacing: 6) {
                    Text("余量")
                        .font(.subheadline.weight(.semibold))
                    if let remaining = model.overallRemainingPercent {
                        Text("最紧张剩余 \(Int(remaining.rounded()))%")
                            .font(.caption)
                            .foregroundStyle(QuotaColor.forRemaining(remaining))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("余量")
                        .font(.headline)
                    if let remaining = model.overallRemainingPercent {
                        Text("最紧张额度剩余 \(Int(remaining.rounded()))%")
                            .font(.caption)
                            .foregroundStyle(QuotaColor.forRemaining(remaining))
                    } else {
                        Text("所有大模型额度，一眼看清")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderless)
                .help("立即刷新")
            }

            if compact {
                Button {
                    model.toggleFloatingPanel()
                } label: {
                    Image(systemName: "xmark")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderless)
                .help("隐藏悬浮窗")
            }
        }
    }
}

private struct ProviderCards: View {
    @ObservedObject var model: AppModel

    var body: some View {
        LazyVStack(spacing: 7) {
            ForEach(model.visibleSnapshots) { snapshot in
                ProviderCard(snapshot: snapshot)
            }
        }
    }
}

private struct ProviderLogoView: View {
    let provider: ProviderID
    let logoSize: CGFloat

    @MainActor private static var cache: [ProviderID: NSImage] = [:]

    var body: some View {
        if let logo = Self.image(for: provider) {
            Image(nsImage: logo)
                .resizable()
                .scaledToFit()
                .frame(width: logoSize, height: logoSize)
        } else {
            Image(systemName: provider.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    @MainActor private static func image(for provider: ProviderID) -> NSImage? {
        if let cached = cache[provider] { return cached }
        guard
            let url = Bundle.module.url(forResource: provider.logoName, withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        cache[provider] = image
        return image
    }
}

/// 套餐徽标，按套餐等级（`ProviderID.planTier`）分色：顶级金色尊贵，高端紫，中端蓝，基础灰。
private struct PlanBadge: View {
    let plan: String
    let provider: ProviderID

    var body: some View {
        let tier = provider.planTier(for: plan)
        Text(plan)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(Self.foreground(tier))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Self.background(tier), in: Capsule())
            .overlay {
                if tier == .top {
                    Capsule().stroke(Self.gold, lineWidth: 0.6)
                }
            }
    }

    static let gold = LinearGradient(
        colors: [Color(red: 0.98, green: 0.82, blue: 0.35), Color(red: 0.80, green: 0.58, blue: 0.12)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static func foreground(_ tier: PlanTier) -> AnyShapeStyle {
        switch tier {
        case .top: AnyShapeStyle(gold)
        case .high: AnyShapeStyle(Color.purple)
        case .mid: AnyShapeStyle(Color.blue)
        case .base: AnyShapeStyle(Color.secondary)
        }
    }

    static func background(_ tier: PlanTier) -> Color {
        switch tier {
        case .top: Color(red: 0.85, green: 0.65, blue: 0.13).opacity(0.16)
        case .high: .purple.opacity(0.14)
        case .mid: .blue.opacity(0.14)
        case .base: .secondary.opacity(0.12)
        }
    }
}

private struct ProviderCard: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                ProviderLogoView(provider: snapshot.provider, logoSize: 13)
                    .frame(width: 22, height: 22)
                    .background(providerGradient, in: RoundedRectangle(cornerRadius: 7))

                Text(snapshot.provider.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let plan = snapshot.plan {
                    PlanBadge(plan: plan, provider: snapshot.provider)
                }
                Text(snapshot.source.rawValue)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(sourceTint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(sourceTint.opacity(0.14), in: Capsule())
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let balance = snapshot.balance {
                    Text(balance.formattedRemaining)
                        .font(.caption.monospacedDigit().weight(.medium))
                }
            }

            if snapshot.windows.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle")
                    Text(snapshot.errorMessage ?? "暂无额度数据")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.windows) { window in
                    QuotaRow(window: window)
                }
            }

            if let error = snapshot.errorMessage, !snapshot.windows.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var sourceTint: Color {
        switch snapshot.source {
        case .officialAPI: .green
        case .localRPC: .blue
        case .cli: .purple
        case .cache: .orange
        }
    }

    private var providerGradient: LinearGradient {
        let colors: [Color]
        switch snapshot.provider {
        case .codex: colors = [.green, .mint]
        case .claude: colors = [.orange, .pink]
        case .kimi: colors = [.indigo, .purple]
        case .glm: colors = [.blue, .cyan]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct QuotaRow: View {
    let window: QuotaWindow

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(window.kind.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(resetLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(QuotaColor.forRemaining(window.remainingPercent))
                    .layoutPriority(1)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.13))
                    Capsule()
                        .fill(QuotaColor.forRemaining(window.remainingPercent).gradient)
                        .frame(width: geometry.size.width * window.remainingPercent / 100)
                }
            }
            .frame(height: 5)
        }
    }

    private var resetLabel: String {
        if let date = window.resetsAt { return date.quotaCountdown }
        if let description = window.resetDescription, !description.isEmpty { return description }
        return "刷新时间未知"
    }
}

enum QuotaColor {
    static func forRemaining(_ value: Double) -> Color {
        if value <= 10 { return .red }
        if value <= 25 { return .orange }
        if value <= 50 { return .yellow }
        return .green
    }
}
