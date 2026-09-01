import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        model.applicationDidFinishLaunching()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.runners.stopMonitoring()
        model.runners.stopAll()
    }
}

@main
struct AmpAutoRunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Amp Auto Runner", id: "main") {
            RunnerDashboardView(model: appDelegate.model)
        }
        .defaultSize(width: 900, height: 620)
        .windowToolbarStyle(.unified)

        Window("Runner Logs", id: "runner-logs") {
            RunnerLogsView(runners: appDelegate.model.runners)
        }
        .defaultSize(width: 900, height: 600)
        .windowToolbarStyle(.unifiedCompact)

        MenuBarExtra("Amp Auto Runner", systemImage: "bolt.fill") {
            StatusBarMenu()
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct StatusBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            showWindow(id: "main")
        } label: {
            Label("Open Runners", systemImage: "macwindow")
        }

        Button {
            showWindow(id: "runner-logs")
        } label: {
            Label("Show Runner Logs", systemImage: "terminal")
        }

        Divider()

        Button("Quit Amp Auto Runner") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func showWindow(id: String) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
