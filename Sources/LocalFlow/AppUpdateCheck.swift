import AppKit
import os

/// "Is there a newer LocalFlow?" — the question the app could not answer at all
/// until now.
///
/// Before this, a user had no in-app route: the only ways to learn a release
/// existed were to visit the GitHub releases page by hand or to have thought to
/// subscribe to release notifications, both of which assume a GitHub account.
/// The person most likely to be running LocalFlow downloaded a zip and has
/// neither.
///
/// Distinct from `ModelUpdateCheck`, which answers "is there a newer speech
/// model?" Two different questions, so two menu items, each naming which thing
/// it checks — a single "Check for updates…" would be ambiguous about the one
/// detail that matters.
///
/// Like the model check: user-initiated only, never on a timer, and it sends
/// nothing about the user. It reads a public release listing.
enum AppUpdateCheck {
    private static let log = Logger(subsystem: "ai.xdlab.LocalFlow", category: "updates")

    private static let repo = "hjl1045/localflow"
    private static let endpoint = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    /// Where to send someone whose release listing can't be read — better than
    /// a dead end when GitHub rate-limits the check.
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    struct Result {
        var installed: String
        var latest: String
        var isNewer: Bool
        var pageURL: URL
        var publishedOn: String?
    }

    // MARK: - Checking

    static func check(installed: String) async throws -> Result {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        // GitHub rejects requests without a User-Agent, and wants this Accept
        // header to pin the response shape.
        request.setValue("LocalFlow update check", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 200..<300: break
        case 403, 429: throw CheckError.rateLimited
        case 404: throw CheckError.noReleases
        default: throw CheckError.badStatus(status)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw CheckError.unreadable
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage

        log.notice("app update check: installed \(installed, privacy: .public), latest \(latest, privacy: .public)")
        return Result(
            installed: installed,
            latest: latest,
            isNewer: isVersion(latest, newerThan: installed),
            pageURL: page,
            publishedOn: (json["published_at"] as? String).map { String($0.prefix(10)) }
        )
    }

    /// Numeric component comparison, because string ordering gets this wrong in
    /// the case that actually matters: "0.10.0" sorts *below* "0.9.0"
    /// lexically.
    ///
    /// Each component is parsed from its LEADING DIGITS, so "2-beta" reads as
    /// 2. Taking `Int("2-beta")` instead yields nil → 0, which would make
    /// 0.2.2-beta look *older* than 0.2.1 and silently never offer a real
    /// update — a failure that shows up as nothing happening. A component with
    /// no leading digit still reads as 0, so a malformed tag means "no update
    /// offered" rather than a crash.
    static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        func components(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let left = components(candidate)
        let right = components(installed)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    enum CheckError: LocalizedError {
        case rateLimited
        case noReleases
        case badStatus(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .rateLimited:
                "GitHub is rate-limiting this Mac's IP. It allows 60 unauthenticated requests an hour, so this usually clears within the hour."
            case .noReleases: "That repository has no published releases."
            case .badStatus(let code): "GitHub returned HTTP \(code)."
            case .unreadable: "GitHub's response wasn't in the expected shape."
            }
        }
    }

    // MARK: - Presenting

    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    @MainActor
    static func run() {
        let installed = installedVersion
        Task {
            do {
                present(try await check(installed: installed))
            } catch {
                log.error("app update check failed: \(error.localizedDescription, privacy: .public)")
                presentFailure(error)
            }
        }
    }

    @MainActor
    private static func present(_ result: Result) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()

        if result.isNewer {
            alert.messageText = "LocalFlow \(result.latest) is available"
            alert.informativeText = """
            You're running \(result.installed).\(result.publishedOn.map { "\n\(result.latest) was published on \($0)." } ?? "")

            Downloads open by double-clicking — they're notarized, so there's no security dialog to work around.
            """
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(result.pageURL)
            }
        } else {
            alert.messageText = "LocalFlow is up to date"
            alert.informativeText = "You're running \(result.installed), which is the latest release."
            alert.runModal()
        }
    }

    @MainActor
    private static func presentFailure(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn’t check for a newer LocalFlow"
        alert.informativeText = """
        \(error.localizedDescription)

        You're running \(installedVersion). The releases page lists what's current.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releasesPage)
        }
    }
}
