import AppKit
import SwiftUI

enum AppIdentity {
#if DEBUG
    static let displayName = "Amp Auto Runner Debug"
    static let windowAutosaveName = "AmpAutoRunnerDebugMainWindow"
    static let supportsLaunchAtLogin = false
#else
    static let displayName = "Amp Auto Runner"
    static let windowAutosaveName = "AmpAutoRunnerMainWindow"
    static let supportsLaunchAtLogin = true
#endif
}

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
    @AppStorage("runnerLogsFontSize") private var interfaceFontSize = 13.0

    var body: some Scene {
        Window(AppIdentity.displayName, id: "main") {
            RunnerDashboardView(model: appDelegate.model)
                .background(WindowFrameAutosaveView(name: AppIdentity.windowAutosaveName))
        }
        .defaultSize(width: 900, height: 620)
        .windowToolbarStyle(.unified)

        MenuBarExtra(AppIdentity.displayName, systemImage: "bolt.fill") {
            StatusBarMenu(model: appDelegate.model)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(after: .sidebar) {
                Divider()

                Button("Zoom In") {
                    interfaceFontSize = min(18, interfaceFontSize + 1)
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(interfaceFontSize >= 18)

                Button("Zoom Out") {
                    interfaceFontSize = max(11, interfaceFontSize - 1)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(interfaceFontSize <= 11)
            }
        }

        Settings {
            AppSettingsView(launchAtLogin: appDelegate.model.launchAtLogin)
        }
    }
}

private struct StatusBarMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel

    var body: some View {
        Button {
            showWindow(id: "main")
        } label: {
            Label("Open Runners", systemImage: "macwindow")
        }

        Button {
            model.setRunnerLogsVisible(true)
            showWindow(id: "main")
        } label: {
            Label("Show Runner Logs", systemImage: "terminal")
        }

        Divider()

        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }

        Divider()

        Button("Quit \(AppIdentity.displayName)") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func showWindow(id: String) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct AppSettingsView: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @AppStorage("runnerLogsFontSize") private var interfaceFontSize = 13.0

    var body: some View {
        Form {
            Section("Appearance") {
                LabeledContent("Interface Font Size") {
                    Stepper(value: $interfaceFontSize, in: 11...18, step: 1) {
                        Text("\(Int(interfaceFontSize)) pt")
                            .monospacedDigit()
                            .frame(minWidth: 38, alignment: .trailing)
                    }
                }
            }

            Section("General") {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                    .disabled(!AppIdentity.supportsLaunchAtLogin)

                if !AppIdentity.supportsLaunchAtLogin {
                    Text("Unavailable in Debug builds to protect the production login item.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let message = launchAtLogin.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)

                    if launchAtLogin.requiresApproval {
                        Button("Open Login Items") {
                            launchAtLogin.openLoginItemsSettings()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            launchAtLogin.refresh()
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: launchAtLogin.setEnabled
        )
    }
}

private struct WindowFrameAutosaveView: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        WindowFrameAutosaveNSView(name: name)
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? WindowFrameAutosaveNSView)?.name = name
        (view as? WindowFrameAutosaveNSView)?.saveWindowFrame()
    }
}

private final class WindowFrameAutosaveNSView: NSView {
    var name: String

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        saveWindowFrame()
    }

    func saveWindowFrame() {
        guard let window, window.frameAutosaveName != name else {
            return
        }
        window.setFrameAutosaveName(name)
    }
}
