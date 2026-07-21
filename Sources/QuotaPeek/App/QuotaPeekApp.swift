import AppKit
import SwiftUI

@main
struct QuotaPeekApp: App {
    @NSApplicationDelegateAdaptor(QuotaPeekAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuDashboardView(model: model)
                .task { model.start() }
        } label: {
            Label("QuotaPeek", systemImage: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: 520, height: 580)
        }
    }
}

@MainActor
final class QuotaPeekAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }
}
