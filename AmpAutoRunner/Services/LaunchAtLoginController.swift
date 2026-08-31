import Combine
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var message: String?

    init() {
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        message = nil

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = error.localizedDescription
        }

        refresh()

        if enabled, SMAppService.mainApp.status == .requiresApproval {
            message = "Approve Amp Auto Runner in System Settings → General → Login Items."
        }
    }

    private func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
