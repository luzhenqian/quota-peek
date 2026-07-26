import AppKit
import SwiftUI
import XCTest
@testable import QuotaPeek

final class EnginePreviewTests: XCTestCase {
    @MainActor
    func testRenderEnginePreviewWhenRequested() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["QUOTAPEEK_ENGINE_PREVIEW"] else {
            throw XCTSkip("Set QUOTAPEEK_ENGINE_PREVIEW to render the engine dock.")
        }

        let hostingView = NSHostingView(
            rootView: FloatingEngineDock(model: AppModel.shared)
                .frame(width: 252, height: 108)
        )
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(x: 0, y: 0, width: 252, height: 108)
        hostingView.layoutSubtreeIfNeeded()
        let png = try renderPNG(hostingView)
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)

        let flowView = NSHostingView(
            rootView: VortexFuelManifold(remaining: 87, isRefreshing: false)
                .frame(width: 150, height: 11)
        )
        flowView.appearance = NSAppearance(named: .darkAqua)
        flowView.frame = NSRect(x: 0, y: 0, width: 150, height: 11)
        flowView.layoutSubtreeIfNeeded()

        let animationWindow = NSWindow(
            contentRect: NSRect(x: 24, y: 24, width: 150, height: 11),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        animationWindow.contentView = flowView
        animationWindow.alphaValue = 0.01
        animationWindow.orderFrontRegardless()
        defer { animationWindow.close() }

        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        let firstFlowFrame = try renderPNG(flowView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.24))
        flowView.layoutSubtreeIfNeeded()
        let secondFlowFrame = try renderPNG(flowView)
        XCTAssertNotEqual(firstFlowFrame, secondFlowFrame, "Fuel manifold must advance between frames.")
    }

    @MainActor
    private func renderPNG(_ view: NSView) throws -> Data {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
