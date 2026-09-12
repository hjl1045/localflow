import AppKit
import os

/// One "Check for updates…" that answers the question a user actually has —
/// *am I current?* — without making them know whether they mean the app or the
/// speech model.
///
/// It replaces two separate menu items. Those named their subsystems precisely,
/// which was defensible and still wrong: nobody opens a menu wondering about
/// their ASR model repository specifically. Her call, 2026-09-12.
///
/// ## What "update" can and cannot mean here
///
/// Neither half can install anything, and the UI must not imply otherwise:
///
/// - **The app** has no self-updater (no Sparkle, no appcast). The action on
///   offer is opening the release page; the download and install are the user's.
/// - **A new upstream model cannot be adopted at all** without a code change.
///   `AppState.models` is a curated four, and a new conversion has to be added
///   to the picker and benchmarked first — "newer ≠ better" is a standing rule
///   here, not a slogan. So the model half is strictly informational.
///
/// Hence one action button, not two, and no "Update" verb anywhere.
///
/// Both halves run concurrently and fail independently: GitHub rate-limiting
/// the release lookup must not hide a model answer that arrived fine.
enum UpdateCheck {
    private static let log = Logger(subsystem: "ai.xdlab.LocalFlow", category: "updates")

    @MainActor
    static func run(appState: AppState) {
        let installed = AppUpdateCheck.installedVersion
        let selectedModel = appState.modelName
        Task {
            async let app = Result { try await AppUpdateCheck.check(installed: installed) }
            async let models = Result { try await ModelUpdateCheck.check(selected: selectedModel) }
            present(app: await app, models: await models, installed: installed)
        }
    }

    // MARK: - Wording

    /// What the alert will say, as data. Kept free of AppKit so the branch
    /// matrix — app ok/newer/failed x models first/none/new/retired/failed — is
    /// checkable without clicking through ten dialogs.
    struct Summary {
        var headline: String
        var body: String
        var offersReleasePage: Bool
        var isWarning: Bool
    }

    static func summary(
        app: Result<AppUpdateCheck.Result, Error>,
        models: Result<ModelUpdateCheck.Result, Error>
    ) -> Summary {
        let appUpdate = try? app.get()
        let modelUpdate = try? models.get()
        let appHasUpdate = appUpdate?.isNewer == true
        let newModels = modelUpdate?.newModels ?? []

        var lines: [String] = []

        // --- app ---
        switch app {
        case .success(let result) where result.isNewer:
            lines.append("**App** — \(result.installed) installed, \(result.latest) available"
                + (result.publishedOn.map { ", published \($0)" } ?? ""))
        case .success(let result):
            lines.append("**App** — \(result.installed), the latest release")
        case .failure(let error):
            lines.append("**App** — couldn't check: \(error.localizedDescription)")
        }

        // --- models ---
        switch models {
        case .success(let result) where result.selectedMissingUpstream:
            lines.append("**Models** — the model you're using (\(result.selected)) is no longer "
                + "published upstream. It keeps working; a fresh install couldn't fetch it.")
        case .success(let result) where result.isFirstCheck:
            lines.append("**Models** — first check, so there's nothing to compare against yet. "
                + "\(result.upstreamCount) published upstream; this is now the baseline.")
        case .success(let result) where !result.newModels.isEmpty:
            lines.append("**Models** — \(result.newModels.count) new since your last check: "
                + result.newModels.prefix(5).joined(separator: ", ")
                + (result.newModels.count > 5 ? ", and \(result.newModels.count - 5) more" : ""))
            // The judgment that keeps this from being an invitation to churn.
            lines.append("Newer is not better — accuracy varies by voice and language, so a new "
                + "model has to be added to the picker and benchmarked before it's worth using.")
        case .success(let result):
            lines.append("**Models** — nothing new; \(result.upstreamCount) published upstream")
        case .failure(let error):
            lines.append("**Models** — couldn't check: \(error.localizedDescription)")
        }

        let verdict = headline(appHasUpdate: appHasUpdate, newModelCount: newModels.count,
                               appFailed: appUpdate == nil, modelsFailed: modelUpdate == nil)
        return Summary(
            headline: verdict.text,
            body: lines.joined(separator: "\n\n").replacingOccurrences(of: "**", with: ""),
            // The release page is the only action either half can offer — and
            // it's also the right fallback when the app check itself failed.
            offersReleasePage: appHasUpdate || appUpdate == nil,
            isWarning: verdict.isWarning
        )
    }

    // MARK: - Presenting

    @MainActor
    private static func present(
        app: Result<AppUpdateCheck.Result, Error>,
        models: Result<ModelUpdateCheck.Result, Error>,
        installed: String
    ) {
        let summary = summary(app: app, models: models)
        log.notice("update check: \(summary.headline, privacy: .public)")

        let alert = NSAlert()
        alert.messageText = summary.headline
        alert.informativeText = summary.body
        alert.alertStyle = summary.isWarning ? .warning : .informational
        if summary.offersReleasePage {
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Not Now")
        } else {
            alert.addButton(withTitle: "OK")
        }

        NSApp.activate(ignoringOtherApps: true)
        // Exactly one runModal(). Putting it inside a condition with an `else`
        // that also ran it showed the dialog a SECOND time when the user chose
        // "Not Now" — the short-circuit made the else branch reachable.
        let choice = alert.runModal()
        if summary.offersReleasePage, choice == .alertFirstButtonReturn {
            let page = (try? app.get())?.pageURL ?? AppUpdateCheck.releasesPage
            NSWorkspace.shared.open(page)
        }
    }

    /// "Everything is up to date" is only sayable when BOTH halves answered and
    /// neither found anything. Treating a *failed* check as "nothing found" —
    /// which the first version did — produces a confident all-clear about a
    /// question that was never answered. That's worse than an error: it stops
    /// the user looking.
    private static func headline(appHasUpdate: Bool, newModelCount: Int,
                                 appFailed: Bool, modelsFailed: Bool) -> (text: String, isWarning: Bool) {
        let plural = newModelCount == 1 ? "" : "s"
        if appFailed && modelsFailed { return ("Couldn’t check for updates", true) }
        if appHasUpdate && newModelCount > 0 {
            return ("A newer LocalFlow and \(newModelCount) new speech model\(plural)", false)
        }
        if appHasUpdate { return ("A newer LocalFlow is available", false) }
        if newModelCount > 0 { return ("\(newModelCount) new speech model\(plural)", false) }
        // Nothing found — so whether that means "current" depends on whether
        // both halves actually reported.
        if appFailed { return ("Couldn’t check for a newer LocalFlow", true) }
        if modelsFailed { return ("Couldn’t check for new speech models", true) }
        return ("Everything is up to date", false)
    }
}

/// `Result` from a throwing async call, so one half failing can't discard the
/// other's answer.
private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
