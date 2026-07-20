import AppKit
import os

private let log = Logger(subsystem: "ai.xdlab.LocalFlow", category: "updates")

/// Launches the companion "Check Model Updates" app from LocalFlow's menu.
///
/// LocalFlow deliberately doesn't know where the repo lives — the companion's
/// launcher has that path baked in at build time (`make check-updates-app`), so
/// there's exactly one place that knows, and it's the one that gets rebuilt when
/// the repo moves. Resolution is by bundle id first, so it works wherever the
/// companion is installed, not just /Applications.
///
/// Measured behavior of that lookup (2026-07-19): LaunchServices resolves the id
/// to ANY registered copy — it followed the bundle when renamed in place, and
/// fell back to the repo's own dist/ copy once /Applications was deleted. That's
/// a graceful degradation (both copies embed the same repo path), but it means
/// the missing-app alert only fires when no copy exists anywhere on disk.
enum UpdateCheck {
    static let bundleIdentifier = "ai.xdlab.LocalFlow.CheckUpdates"
    private static let fallbackPath = "/Applications/Check Model Updates.app"

    /// Returns the companion's URL, or nil if it isn't installed.
    static func companionURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        let fallback = URL(fileURLWithPath: fallbackPath)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    @MainActor
    static func launch() {
        guard let url = companionURL() else {
            log.error("companion app not found")
            presentMissingAlert()
            return
        }
        log.notice("launching update check: \(url.path)")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The companion ships with LocalFlow via `make install`, so if it's gone
    /// the fix is to reinstall — say that rather than failing silently.
    @MainActor
    private static func presentMissingAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "“Check Model Updates” isn’t installed"
        alert.informativeText = """
        It's installed alongside LocalFlow. From the LocalFlow repo, run:

            make install

        That installs both apps to /Applications.
        """
        alert.alertStyle = .informational
        alert.runModal()
    }
}
