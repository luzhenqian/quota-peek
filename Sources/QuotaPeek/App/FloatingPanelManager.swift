import AppKit
import SwiftUI

@MainActor
final class FloatingPanelManager: ObservableObject {
    static let shared = FloatingPanelManager()

    @Published private(set) var isCollapsed = false

    private var panel: NSPanel?
    private var expandedSize = NSSize(width: 300, height: 455)
    private let collapsedSize = NSSize(width: 252, height: 108)

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
        panel.minSize = NSSize(width: 260, height: 300)
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
        expandedSize = panel.frame.size
        panel.minSize = collapsedSize
        panel.maxSize = collapsedSize
        withAnimation(.snappy(duration: 0.28)) {
            isCollapsed = true
        }
        animate(panel: panel, to: frameAnchoredAtTopRight(of: panel.frame, size: collapsedSize))
    }

    func expand() {
        guard let panel, isCollapsed else { return }
        panel.minSize = NSSize(width: 260, height: 300)
        panel.maxSize = NSSize(width: 10_000, height: 10_000)
        withAnimation(.snappy(duration: 0.28)) {
            isCollapsed = false
        }
        animate(panel: panel, to: frameAnchoredAtTopRight(of: panel.frame, size: expandedSize))
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
