import AppKit
import SwiftUI

@MainActor
final class FloatingPanelManager {
    static let shared = FloatingPanelManager()

    private var panel: NSPanel?

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
        panel.minSize = NSSize(width: 260, height: 300)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentView = NSHostingView(rootView: FloatingDashboardView(model: model))

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
}
