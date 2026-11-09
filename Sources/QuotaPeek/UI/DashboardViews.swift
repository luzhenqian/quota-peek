import AppKit
import SwiftUI

struct MenuBarControlsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            model.toggleFloatingPanel()
        } label: {
            Label(
                FloatingPanelManager.shared.isVisible ? "隐藏悬浮窗" : "显示悬浮窗",
                systemImage: "macwindow.on.rectangle"
            )
        }

        Button {
            Task { await model.refreshAll() }
        } label: {
            Label(model.isRefreshing ? "正在刷新…" : "立即刷新", systemImage: "arrow.clockwise")
        }
        .disabled(model.isRefreshing)
        .keyboardShortcut("r")

        Divider()

        Button {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("设置…", systemImage: "gearshape")
        }

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("退出余量", systemImage: "power")
        }
        .keyboardShortcut("q")
    }
}

/// 把「装下全部卡片所需的高度」从内容侧冒泡到窗口侧。
private struct PanelContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

private extension View {
    /// 测量自身高度并累加进 PanelContentHeightKey。
    func measuringPanelHeight() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: PanelContentHeightKey.self, value: proxy.size.height)
            }
        }
    }
}

struct FloatingDashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DashboardHeader(model: model, compact: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .measuringPanelHeight()

            ScrollView {
                ProviderCards(model: model)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    // 测量的是滚动内容本身而非视口，所以不会和窗口尺寸形成反馈循环。
                    .measuringPanelHeight()
            }
        }
        .onPreferenceChange(PanelContentHeightKey.self) { height in
            Task { @MainActor in
                FloatingPanelManager.shared.updatePreferredHeight(height)
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

struct FloatingPanelRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var panelManager = FloatingPanelManager.shared

    var body: some View {
        if panelManager.isCollapsed {
            FloatingEngineDock(model: model)
        } else {
            FloatingDashboardView(model: model)
        }
    }
}

struct FloatingEngineDock: View {
    @ObservedObject var model: AppModel
    @State private var coreHovering = false

    private var selectedSnapshots: [ProviderSnapshot] {
        let all = model.visibleSnapshots
        let recommended = all.first { $0.provider == model.recommendedProvider }
        let urgent = all
            .filter { $0.provider != model.recommendedProvider }
            .sorted {
                ($0.minimumRemainingPercent ?? -1) < ($1.minimumRemainingPercent ?? -1)
            }

        var selected = Array(urgent.prefix(recommended == nil ? 4 : 3))
        if let recommended { selected.append(recommended) }
        return selected
    }

    private var overflowCount: Int {
        max(0, model.visibleSnapshots.count - selectedSnapshots.count)
    }

    var body: some View {
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: 17,
                bottomLeadingRadius: 17,
                bottomTrailingRadius: 42,
                topTrailingRadius: 42,
                style: .continuous
            )
            .fill(.thickMaterial)

            UnevenRoundedRectangle(
                topLeadingRadius: 17,
                bottomLeadingRadius: 17,
                bottomTrailingRadius: 42,
                topTrailingRadius: 42,
                style: .continuous
            )
                .stroke(
                    LinearGradient(
                        colors: [.cyan.opacity(0.62), .indigo.opacity(0.24), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            HStack(spacing: 7) {
                fuelRail

                EngineCore(
                    remaining: model.overallRemainingPercent ?? 100,
                    isRefreshing: model.isRefreshing,
                    isHovering: coreHovering
                ) {
                    FloatingPanelManager.shared.expand()
                }
                .onHover { coreHovering = $0 }
            }
            .padding(8)
        }
        .frame(width: 252, height: 108)
        .help("AI 配额引擎 · 点击核心展开")
    }

    private var fuelRail: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.isRefreshing ? Color.cyan : Color.green)
                    .frame(width: 5, height: 5)
                    .shadow(color: model.isRefreshing ? .cyan : .green, radius: 3)
                Text(model.isRefreshing ? "SYNCING ENGINE" : "AI FUEL BUS")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.visibleSnapshots.count) MODULES")
                    .font(.system(size: 6.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.22))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }

                VortexFuelManifold(
                    remaining: model.overallRemainingPercent ?? 100,
                    isRefreshing: model.isRefreshing
                )
                    .frame(height: 11)
                    .padding(.horizontal, 5)

                HStack(spacing: 4) {
                    ForEach(Array(selectedSnapshots.enumerated()), id: \.offset) { _, snapshot in
                        FuelCartridge(
                            snapshot: snapshot,
                            isDocked: snapshot.provider == model.recommendedProvider
                        )
                    }

                    if overflowCount > 0 {
                        VStack(spacing: 2) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 8, weight: .bold))
                            Text("+\(overflowCount)")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 23, height: 60)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
        }
        .frame(width: 160)
        .frame(maxHeight: .infinity)
    }
}

private struct FuelCartridge: View {
    let snapshot: ProviderSnapshot
    let isDocked: Bool
    @State private var isHovering = false

    private var remaining: Double {
        snapshot.headlineWindow?.remainingPercent ?? 0
    }

    private var standaloneBalance: ProviderBalance? {
        snapshot.headlineWindow == nil ? snapshot.balance : nil
    }

    var body: some View {
        VStack(spacing: 2.5) {
            ZStack(alignment: .topTrailing) {
                ProviderLogoView(provider: snapshot.provider, logoSize: 11)
                    .frame(width: 16, height: 16)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))

                if snapshot.account?.isEmpty == false {
                    Circle()
                        .fill(.cyan)
                        .frame(width: 4, height: 4)
                        .offset(x: 2, y: -2)
                }
            }

            GeometryReader { geometry in
                if let balance = standaloneBalance {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.38))
                        Image(systemName: balance.remaining > 0 ? "banknote.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(balance.remaining > 0 ? Color.mint : Color.red)
                            .shadow(color: balance.remaining > 0 ? Color.mint.opacity(0.65) : Color.red.opacity(0.65), radius: 3)
                    }
                } else {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.38))

                        VStack(spacing: 5) {
                            ForEach(0..<3, id: \.self) { _ in
                                Rectangle()
                                    .fill(.white.opacity(0.08))
                                    .frame(height: 0.5)
                            }
                        }
                        .padding(.horizontal, 2)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(QuotaColor.forRemaining(remaining).gradient)
                            .frame(height: max(2, geometry.size.height * remaining / 100))
                            .overlay(alignment: .top) {
                                Rectangle()
                                    .fill(.white.opacity(0.42))
                                    .frame(height: 1)
                            }
                            .shadow(color: QuotaColor.forRemaining(remaining).opacity(0.55), radius: 3)

                        LinearGradient(
                            colors: [.white.opacity(0.2), .clear, .black.opacity(0.12)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .frame(width: 16, height: 29)

            Text(standaloneBalance?.compactFormattedRemaining ?? "\(Int(remaining.rounded()))%")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(standaloneBalance == nil ? QuotaColor.forRemaining(remaining) : Color.mint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: 24, height: 9)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 3)
        .background(
            LinearGradient(
                colors: [.white.opacity(isHovering ? 0.18 : 0.13), .white.opacity(0.03)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isDocked ? Color.cyan.opacity(0.95) : Color.white.opacity(0.12), lineWidth: isDocked ? 1.4 : 0.8)
        }
        .overlay(alignment: .trailing) {
            if isDocked {
                Capsule()
                    .fill(.cyan)
                    .frame(width: 4, height: 16)
                    .offset(x: 4)
                    .shadow(color: .cyan, radius: 4)
            }
        }
        .offset(y: isHovering ? -2 : 0)
        .scaleEffect(isHovering ? 1.04 : 1)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .shadow(color: isDocked ? .cyan.opacity(0.38) : .clear, radius: 5)
        .onHover { isHovering = $0 }
        .help(cartridgeHelp)
        .frame(width: 27)
    }

    private var cartridgeHelp: String {
        let account = snapshot.account.map { " · \($0)" } ?? ""
        if let balance = standaloneBalance {
            return "\(snapshot.provider.shortName)\(account) · 账户余额 \(balance.formattedRemaining) · 按量计费"
        }
        return "\(snapshot.provider.shortName)\(account) · 剩余 \(Int(remaining.rounded()))%"
    }
}

private struct EngineCore: View {
    let remaining: Double
    let isRefreshing: Bool
    let isHovering: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(white: 0.18), Color(white: 0.07), Color.black.opacity(0.86)],
                            center: .center,
                            startRadius: 2,
                            endRadius: 38
                        )
                    )

                Circle()
                    .stroke(.white.opacity(0.1), lineWidth: 5)

                Circle()
                    .trim(from: 0, to: max(0.015, remaining / 100))
                    .stroke(
                        QuotaColor.forRemaining(remaining).gradient,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: QuotaColor.forRemaining(remaining).opacity(0.7), radius: 4)

                EngineTickRing()
                    .stroke(.white.opacity(0.25), lineWidth: 1)
                    .padding(7)

                TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let speed = isRefreshing ? 320.0 : 32.0

                    EngineRotor()
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.cyan.opacity(0.98), .blue, .indigo],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .padding(14)
                        .rotationEffect(.degrees(time * speed))
                        .drawingGroup()
                }

                TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let pulse = (sin(time * (isRefreshing ? 9.5 : 4.2)) + 1) / 2

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white, .cyan, .blue],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: 7
                            )
                        )
                        .frame(width: 9 + pulse * 1.4, height: 9 + pulse * 1.4)
                        .shadow(color: .cyan, radius: 4 + pulse * 3)
                }

                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(isHovering ? 0.9 : 0))
                    .offset(y: 23)
            }
            .scaleEffect(isHovering ? 1.06 : 1)
            .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .frame(width: 68, height: 68)
        .help("展开额度面板")
    }
}

private struct EngineTickRing: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer - 3
        var path = Path()

        for index in 0..<16 {
            let angle = CGFloat(index) * 2 * .pi / 16
            path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        return path
    }
}

private struct EngineRotor: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) * 0.36
        let innerRadius = outerRadius * 0.42
        var path = Path()

        for index in 0..<6 {
            let angle = CGFloat(index) * .pi / 3
            let nextAngle = angle + .pi / 7
            path.move(to: CGPoint(
                x: center.x + cos(angle) * innerRadius,
                y: center.y + sin(angle) * innerRadius
            ))
            path.addQuadCurve(
                to: CGPoint(
                    x: center.x + cos(nextAngle) * outerRadius,
                    y: center.y + sin(nextAngle) * outerRadius
                ),
                control: CGPoint(
                    x: center.x + cos(angle + .pi / 12) * outerRadius,
                    y: center.y + sin(angle + .pi / 12) * outerRadius
                )
            )
            path.addLine(to: center)
            path.closeSubpath()
        }
        return path
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
                    FloatingPanelManager.shared.collapse()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderless)
                .help("收起为 AI 配额引擎")

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
                ProviderCard(snapshot: snapshot, isRecommended: snapshot.provider == model.recommendedProvider)
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
    let isRecommended: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if isRecommended {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text("推荐优先使用")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    LinearGradient(colors: [.indigo, .cyan], startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
            }

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

                if let balance = snapshot.balance, !snapshot.windows.isEmpty {
                    Text(balance.formattedRemaining)
                        .font(.caption.monospacedDigit().weight(.medium))
                }
            }

            if let balance = snapshot.balance, snapshot.windows.isEmpty {
                BalanceQuotaView(balance: balance)
            } else if snapshot.windows.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle")
                    Text(snapshot.errorMessage ?? "暂无额度数据")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                let heroKind = Self.heroKind(among: snapshot.windows)
                ForEach(Self.ordered(snapshot.windows)) { window in
                    if window.kind == heroKind {
                        HeroQuotaRow(window: window)
                    } else {
                        QuotaRow(window: window)
                    }
                }
            }

            if let error = snapshot.errorMessage, !snapshot.windows.isEmpty || snapshot.balance != nil {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(
            isRecommended ? Color.cyan.opacity(0.08) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isRecommended ? Color.cyan.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: isRecommended ? 1.4 : 1)
        }
    }

    /// 该卡片里最该突出显示的窗口：优先月额度，没有月额度就用周额度；
    /// 5 小时 / MCP工具 / 具体模型这类并列的短周期或分项限额没有天然的"头号指标"，不强行突出。
    private static func heroKind(among windows: [QuotaWindow]) -> QuotaWindowKind? {
        switch ordered(windows).first?.kind {
        case .monthly: .monthly
        case .weekly: .weekly
        default: nil
        }
    }

    /// 用户最关心月额度，其次每周，再是 5 小时窗口等短周期。同优先级内保持原始顺序（稳定排序）。
    private static func ordered(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        windows.enumerated()
            .sorted { lhs, rhs in
                let (lp, rp) = (lhs.element.kind.displayPriority, rhs.element.kind.displayPriority)
                return lp != rp ? lp < rp : lhs.offset < rhs.offset
            }
            .map(\.element)
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
        case .grok: colors = [Color(white: 0.35), Color(white: 0.1)]
        case .deepseek: colors = [.blue, .indigo]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// DeepSeek 一类按量计费 Provider 只有可用金额，没有可用于计算百分比的固定上限。
private struct BalanceQuotaView: View {
    let balance: ProviderBalance

    private var tint: Color {
        balance.remaining > 0 ? .mint : .red
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: balance.remaining > 0 ? "banknote.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("账户余额")
                    .font(.caption.weight(.semibold))
                Text(balance.limit == nil ? "按量计费 · 无固定额度上限" : "可用余额")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Text(balance.formattedRemaining)
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(balance.remaining > 0 ? Color.primary : Color.red)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(8)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        }
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
                Text(window.resetLabel)
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
                        .frame(width: geometry.size.width * (100 - window.remainingPercent) / 100)
                }
            }
            .frame(height: 5)
        }
    }
}

/// 每月额度是用户最关心的指标，用更大的字号和更粗的进度条突出，和其余窗口的紧凑样式拉开层级。
private struct HeroQuotaRow: View {
    let window: QuotaWindow

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text(window.kind.displayName)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(window.resetLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(QuotaColor.forRemaining(window.remainingPercent))
                    .layoutPriority(1)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                    Capsule()
                        .fill(QuotaColor.forRemaining(window.remainingPercent).gradient)
                        .frame(width: geometry.size.width * (100 - window.remainingPercent) / 100)
                }
            }
            .frame(height: 9)
        }
        .padding(.bottom, 2)
    }
}

private extension QuotaWindow {
    var resetLabel: String {
        if let date = resetsAt { return date.quotaCountdown }
        if let description = resetDescription, !description.isEmpty { return description }
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
