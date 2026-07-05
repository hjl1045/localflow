import ServiceManagement
import os

/// "Launch at login" backed by `SMAppService.mainApp` (macOS 13+). Registering
/// the main app makes macOS start LocalFlow at login so the hotkey is always
/// live without relaunching. Status is read from the system, never cached, so
/// the Settings toggle reflects reality even if the user changes it in
/// System Settings → General → Login Items.
enum LoginItem {
    private static let log = Logger(subsystem: "ai.xdlab.LocalFlow", category: "loginitem")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item. Failures are logged,
    /// not thrown, so a toggle tap can never crash the app; the caller re-reads
    /// `isEnabled` afterwards to reflect the real outcome.
    static func setEnabled(_ enabled: Bool) {
        do {
            switch (enabled, SMAppService.mainApp.status) {
            case (true, let status) where status != .enabled:
                try SMAppService.mainApp.register()
            case (false, .enabled):
                try SMAppService.mainApp.unregister()
            default:
                break // already in the requested state
            }
        } catch {
            log.error("login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }
}
