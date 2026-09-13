import Foundation
import ServiceManagement

/// Manages launch-at-login registration using modern macOS 13+ `SMAppService.mainApp`.
///
/// NOTE: Uses modern SMAppService, completely avoiding the deprecated SMLoginItemSetEnabled.
@MainActor
public final class LaunchAtLoginManager: ObservableObject {
    public static let shared = LaunchAtLoginManager()

    @Published public var isEnabled: Bool = false
    @Published public var statusMessage: String? = nil

    public init() {
        refreshStatus()
    }

    public func refreshStatus() {
        let status = SMAppService.mainApp.status
        self.isEnabled = (status == .enabled)
        switch status {
        case .enabled:
            self.statusMessage = nil
        case .requiresApproval:
            self.statusMessage = "Approval required in System Settings > General > Login Items"
        case .notRegistered:
            self.statusMessage = nil
        case .notFound:
            self.statusMessage = nil
        @unknown default:
            self.statusMessage = nil
        }
    }

    public func setEnabled(_ enable: Bool) {
        do {
            if enable {
                if SMAppService.mainApp.status == .enabled { return }
                try SMAppService.mainApp.register()
            } else {
                if SMAppService.mainApp.status == .notRegistered { return }
                try SMAppService.mainApp.unregister()
            }
            refreshStatus()
        } catch {
            print("[LaunchAtLoginManager] Error setting launch at login to \(enable): \(error.localizedDescription)")
            refreshStatus()
        }
    }
}
