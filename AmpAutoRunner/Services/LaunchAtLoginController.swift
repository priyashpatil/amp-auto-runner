import Combine
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
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
            let errorMessage = error.localizedDescription
            refresh()
            if !requiresApproval {
                message = errorMessage
            }
            return
        }

        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
        message = requiresApproval
            ? "Allow Amp Auto Runner in System Settings → General → Login Items."
            : nil
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
