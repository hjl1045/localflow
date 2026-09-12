import AppKit
import os

/// "Is there a newer speech model than the one I'm running?" — answered from
/// inside the app.
///
/// This used to live in a separate "Check Model Updates.app" that shelled out
/// to a Python script in the repo, with the repo path baked in at build time —
/// so it did nothing at all for anyone who downloaded LocalFlow. The check
/// itself never needed the repo: it is one public HTTP GET against Hugging
/// Face's API, which the app can do on its own.
///
/// What it deliberately does NOT do: check the app's own version (that's a
/// separate feature), run in the background, or phone home on a schedule. It
/// fires only when the menu item is clicked — the one off-machine request
/// LocalFlow makes, and only because the user asked a question that can't be
/// answered locally.
enum ModelUpdateCheck {
    private static let log = Logger(subsystem: "ai.xdlab.LocalFlow", category: "updates")

    /// The WhisperKit CoreML conversions LocalFlow's models come from. Same repo
    /// `scripts/check-updates.py` watches, so the app and the dev chore agree on
    /// what "upstream" means.
    private static let repo = "argmaxinc/whisperkit-coreml"
    private static let endpoint = URL(string: "https://huggingface.co/api/models/\(repo)")!

    /// Remembers what upstream looked like last time, so a check can report
    /// what *changed* rather than what merely exists.
    private static let snapshotKey = "modelSnapshotFolders"
    private static let snapshotDateKey = "modelSnapshotCheckedAt"

    struct Result {
        var repoLastModified: String?
        /// Model folders that appeared since the last check.
        var newModels: [String]
        /// True on the very first check, when there is no baseline to diff
        /// against and everything upstream would look "new".
        var isFirstCheck: Bool
        var lastChecked: Date?
        /// True when the model currently selected no longer exists upstream —
        /// worth knowing, because a re-download would fail.
        var selectedMissingUpstream: Bool
        var selected: String
        var upstreamCount: Int
    }

    // MARK: - Checking

    /// Queries the repo and reports what changed since the last check.
    ///
    /// The baseline is a stored snapshot, matching `scripts/check-updates.py`.
    /// Diffing against the four models the app *offers* was the obvious first
    /// idea and it's wrong: the app curates 4 of ~27 on purpose, so that diff
    /// reports 23 rows of "not curated" as though they were news. What answers
    /// "is there an update?" is what appeared since you last looked.
    static func check(selected: String) async throws -> Result {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("LocalFlow model update check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CheckError.badStatus(code)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CheckError.unreadable
        }
        let siblings = json["siblings"] as? [[String: Any]] ?? []
        // Model folders are the first path component of every nested file —
        // the same derivation the script uses, so the two can't drift.
        let upstream = Set(siblings.compactMap { sibling -> String? in
            guard let path = sibling["rfilename"] as? String, path.contains("/") else { return nil }
            return String(path.split(separator: "/")[0])
        })
        guard !upstream.isEmpty else { throw CheckError.unreadable }

        let defaults = UserDefaults.standard
        let known = Set(defaults.stringArray(forKey: snapshotKey) ?? [])
        let lastChecked = defaults.object(forKey: snapshotDateKey) as? Date
        let newModels = known.isEmpty ? [] : upstream.subtracting(known).sorted()

        // Settings stores WhisperKit's short id ("base"); upstream folders are
        // prefixed ("openai_whisper-base"), so compare on the suffix.
        let selectedExists = upstream.contains { $0.hasSuffix(selected) }

        defaults.set(upstream.sorted(), forKey: snapshotKey)
        defaults.set(Date(), forKey: snapshotDateKey)

        log.notice("model check: \(upstream.count) upstream, \(newModels.count) new since last check")
        return Result(
            repoLastModified: (json["lastModified"] as? String).map { String($0.prefix(10)) },
            newModels: newModels,
            isFirstCheck: known.isEmpty,
            lastChecked: lastChecked,
            selectedMissingUpstream: !selectedExists,
            selected: selected,
            upstreamCount: upstream.count
        )
    }

    enum CheckError: LocalizedError {
        case badStatus(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): "Hugging Face returned HTTP \(code)."
            case .unreadable: "Hugging Face's response wasn't in the expected shape."
            }
        }
    }

    // MARK: - Presenting

    @MainActor
    static func run(appState: AppState) {
        let selected = appState.modelName
        Task {
            do {
                let result = try await check(selected: selected)
                present(result)
            } catch {
                log.error("model check failed: \(error.localizedDescription, privacy: .public)")
                presentFailure(error)
            }
        }
    }

    @MainActor
    private static func present(_ result: Result) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()

        var lines = ["Currently using: \(result.selected)"]
        if let modified = result.repoLastModified {
            lines.append("Model repo last updated: \(modified)")
        }
        lines.append("\(result.upstreamCount) models published upstream")

        if result.selectedMissingUpstream {
            alert.messageText = "Your model is no longer published upstream"
            lines.append("")
            lines.append("It keeps working — it's already downloaded — but a fresh install couldn't fetch it.")
            alert.alertStyle = .warning
        } else if result.isFirstCheck {
            alert.messageText = "Baseline saved"
            lines.append("")
            lines.append("This was the first check, so there's nothing to compare against yet. From now on this will report what's newly published.")
        } else if result.newModels.isEmpty {
            alert.messageText = "No new speech models"
            lines.append("")
            lines.append(result.lastChecked.map { "Nothing new since you last checked on \(Self.day.string(from: $0))." }
                ?? "Nothing new since the last check.")
        } else {
            alert.messageText = "\(result.newModels.count) new speech model\(result.newModels.count == 1 ? "" : "s")"
            lines.append("")
            lines.append(result.newModels.prefix(8).joined(separator: "\n"))
            if result.newModels.count > 8 {
                lines.append("…and \(result.newModels.count - 8) more")
            }
            lines.append("")
            // The script says this and it's the part worth keeping: a newer
            // conversion is not automatically a better one for her voice.
            lines.append("Newer is not the same as better. Accuracy varies by voice and language, so these are worth benchmarking before switching.")
        }

        alert.informativeText = lines.joined(separator: "\n")
        alert.runModal()
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    @MainActor
    private static func presentFailure(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn’t check for model updates"
        alert.informativeText = """
        \(error.localizedDescription)

        This check needs the network — it asks Hugging Face which speech models exist. Dictation itself is unaffected and stays entirely on this Mac.
        """
        alert.alertStyle = .warning
        alert.runModal()
    }
}
