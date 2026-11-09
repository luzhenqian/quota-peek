import AppKit
import SwiftUI

@MainActor
final class FloatingPanelManager: ObservableObject {
    static let shared = FloatingPanelManager()

    @Published private(set) var isCollapsed = false

    private var panel: NSPanel?
    private var expandedWidth: CGFloat = 300
    private let collapsedSize = NSSize(width: 252, height: 108)
    /// 装下全部卡片所需的高度，由 FloatingDashboardView 实测后回传。
    private var preferredHeight: CGFloat = 455

    private static let minimumExpandedHeight: CGFloat = 140
    /// 上下各留一点，别让面板顶满屏幕。
    private static let screenMargin: CGFloat = 48

    var isVisible: Bool { panel?.isVisible == true }

    func show(model: AppModel) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 455),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = false
        panel.minSize = NSSize(width: 260, height: Self.minimumExpandedHeight)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentView = NSHostingView(rootView: FloatingPanelRootView(model: model))

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - panel.frame.width - 24,
                y: frame.maxY - panel.frame.height - 24
            ))
        }

        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func collapse() {
        guard let panel, !isCollapsed else { return }
        expandedWidth = panel.frame.width
        panel.minSize = collapsedSize
        panel.maxSize = collapsedSize
        withAnimation(.snappy(duration: 0.28)) {
            isCollapsed = true
        }
        animate(panel: panel, to: frameAnchoredAtTopRight(of: panel.frame, size: collapsedSize))
    }

    func expand() {
        guard let panel, isCollapsed else { return }
        panel.minSize = NSSize(width: 260, height: Self.minimumExpandedHeight)
        panel.maxSize = NSSize(width: 10_000, height: 10_000)
        withAnimation(.snappy(duration: 0.28)) {
            isCollapsed = false
        }
        let size = NSSize(width: expandedWidth, height: resolvedHeight(for: preferredHeight))
        animate(panel: panel, to: frameAnchoredAtTopRight(of: panel.frame, size: size))
    }

    /// 内容侧实测的所需高度。窗口据此贴合内容，仅在超出屏幕时才回落到滚动。
    func updatePreferredHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        preferredHeight = height

        guard let panel, !isCollapsed else { return }
        let target = resolvedHeight(for: height)
        // 小于 1pt 的抖动不值得重排窗口。
        guard abs(panel.frame.height - target) > 1 else { return }

        let size = NSSize(width: panel.frame.width, height: target)
        panel.setFrame(frameAnchoredAtTopRight(of: panel.frame, size: size), display: true)
    }

    private func resolvedHeight(for height: CGFloat) -> CGFloat {
        let available = (panel?.screen ?? NSScreen.main)?.visibleFrame.height ?? height
        let ceiling = max(Self.minimumExpandedHeight, available - Self.screenMargin)
        return min(max(height, Self.minimumExpandedHeight), ceiling)
    }

    private func animate(panel: NSPanel, to frame: NSRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func frameAnchoredAtTopRight(of frame: NSRect, size: NSSize) -> NSRect {
        var origin = NSPoint(x: frame.maxX - size.width, y: frame.maxY - size.height)
        if let screen = panel?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return NSRect(origin: origin, size: size)
    }
}
