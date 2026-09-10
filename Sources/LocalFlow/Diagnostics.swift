import AppKit
import ApplicationServices
import AVFoundation
import KeyboardShortcuts
import os

/// Everything a bug report carries, assembled in one place so that every
/// delivery path — clipboard, saved file, the Linear intake email — sends
/// exactly the same bytes, and so what leaves the machine is reviewable in one
/// screenful of code rather than scattered across the UI that sends it.
///
/// What's in here is machine *configuration*: versions, which model, which
/// permissions, which hotkeys. Two deliberate exclusions:
///
/// - **Transcript text is opt-in per report** (`includeTranscript`). It's the
///   single most useful field for a dictation bug and the most sensitive thing
///   the app holds, so it can't be a default.
/// - **Audio is never included.** There's no path that would attach a
///   recording; if a report needs one she can ask for it directly.
///
/// The log tail is safe to include without review: every log call in this
/// codebase records *counts*, never content (`transcript: 61 chars`,
/// `inject: chars=147`), and os_log redacts interpolated strings as `<private>`
/// unless they're explicitly marked public. Verified across all six categories
/// 2026-09-09 — re-check it if you ever log a transcript.
struct Diagnostics {
    var generatedAt = Date()
    var appVersion: String
    var appBuild: String
    var systemVersion: String
    var hardwareModel: String
    var asrModel: String
    var language: String
    var cleanupEnabled: Bool
    var ollamaWarning: String?
    var pushToTalk: String
    var toggleDictation: String
    var overlayPosition: String
    var microphoneAccess: String
    var accessibilityTrusted: Bool
    var launchAtLogin: Bool
    var status: String
    /// Present only when a crash report was found at launch.
    var crash: CrashReport?
    /// Present only when the reporter ticked the box.
    var transcript: String?
    var logTail: String
    /// What the reporter typed. Empty is allowed — a crash report with no
    /// description still beats no report.
    var userDescription: String = ""

    // MARK: - Collection

    @MainActor
    static func collect(
        appState: AppState,
        includeTranscript: Bool = false,
        crash: CrashReport? = nil
    ) async -> Diagnostics {
        let logTail = await Task.detached(priority: .userInitiated) { LogTail.recent() }.value

        return Diagnostics(
            appVersion: bundleString("CFBundleShortVersionString"),
            appBuild: bundleString("CFBundleVersion"),
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: sysctlString("hw.model"),
            asrModel: appState.modelName,
            language: appState.languageCode,
            cleanupEnabled: appState.cleanupEnabled,
            ollamaWarning: appState.cleanupEnabled ? appState.ollamaHealth.warning : nil,
            pushToTalk: KeyboardShortcuts.getShortcut(for: .pushToTalk)?.description ?? "unset",
            toggleDictation: KeyboardShortcuts.getShortcut(for: .toggleDictation)?.description ?? "unset",
            overlayPosition: appState.overlayPosition.rawValue,
            microphoneAccess: microphoneAccess(),
            accessibilityTrusted: AXIsProcessTrusted(),
            launchAtLogin: LoginItem.isEnabled,
            status: appState.live ? appState.status.label : "n/a — headless dump",
            crash: crash,
            transcript: includeTranscript ? appState.recentTranscripts.first?.text : nil,
            logTail: logTail
        )
    }

    // MARK: - Rendering

    /// A one-line subject for the Linear issue this becomes.
    var subject: String {
        if let crash {
            // No `appVersion` here: the summary already carries the version
            // that crashed, which is the relevant one — a crash is often
            // reported from a build newer than the one that produced it.
            return "LocalFlow crash — \(crash.summary)"
        }
        let trimmed = userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "LocalFlow \(appVersion) feedback" }
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        let clipped = firstLine.count > 72 ? String(firstLine.prefix(72)) + "…" : firstLine
        return "LocalFlow \(appVersion): \(clipped)"
    }

    /// The report body. Markdown, because it lands in a Linear issue
    /// description — which renders it.
    func body(includeFullCrash: Bool) -> String {
        var out = ""

        let described = userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !described.isEmpty {
            out += "\(described)\n\n"
        }

        if let crash {
            out += "## Crash\n\n"
            out += "- File: `\(crash.fileName)`\n"
            out += "- When: \(Self.timestamp.string(from: crash.date))\n"
            out += "- What: \(crash.summary)\n\n"
            if includeFullCrash {
                out += "<details><summary>Full .ips</summary>\n\n```\n\(crash.contents)\n```\n\n</details>\n\n"
            } else {
                out += "_Full `.ips` not included in email — ask the reporter for the saved report._\n\n"
            }
        }

        out += "## Setup\n\n"
        out += "| | |\n| -- | -- |\n"
        out += "| LocalFlow | \(appVersion) (build \(appBuild)) |\n"
        out += "| macOS | \(systemVersion) |\n"
        out += "| Mac | \(hardwareModel) |\n"
        out += "| ASR model | \(asrModel) |\n"
        out += "| Language | \(language) |\n"
        out += "| AI cleanup | \(cleanupEnabled ? "on" : "off")\(ollamaWarning.map { " — \($0)" } ?? "") |\n"
        out += "| Push-to-talk | \(pushToTalk) |\n"
        out += "| Hands-free | \(toggleDictation) |\n"
        out += "| Overlay | \(overlayPosition) |\n"
        out += "| Microphone | \(microphoneAccess) |\n"
        out += "| Accessibility | \(accessibilityTrusted ? "trusted" : "NOT trusted — injection will fail") |\n"
        out += "| Launch at login | \(launchAtLogin ? "on" : "off") |\n"
        out += "| Status when reported | \(status) |\n"
        out += "| Report generated | \(Self.timestamp.string(from: generatedAt)) |\n\n"

        if let transcript {
            out += "## Last transcript (included by the reporter)\n\n```\n\(transcript)\n```\n\n"
        }

        out += "## Recent log\n\n"
        out += logTail.isEmpty
            ? "_No log lines in the window — see `docs/FEEDBACK.md` for reading them by hand._\n"
            : "```\n\(logTail)\n```\n"

        return out
    }

    /// What the preview pane shows and the clipboard/file paths write: the full
    /// thing, crash file included.
    var fullText: String {
        "# \(subject)\n\n" + body(includeFullCrash: true)
    }

    // MARK: - Pieces

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter
    }()

    private static func bundleString(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    private static func microphoneAccess() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "granted"
        case .denied: "DENIED — dictation will record silence"
        case .restricted: "restricted by policy"
        case .notDetermined: "not yet asked"
        @unknown default: "unknown"
        }
    }
}

/// Reads LocalFlow's own recent log lines back out of the unified log.
///
/// `log show` is a subprocess because there is no API to read your own past
/// log entries — `OSLog`/`OSLogStore` can do it on iOS but the entry point
/// that works for a non-sandboxed Mac app without extra entitlements is the
/// command-line tool. It can take a couple of seconds, hence the timeout and
/// the detached call site.
enum LogTail {
    private static let log = Logger(subsystem: "ai.xdlab.LocalFlow", category: "diagnostics")
    /// The line cap, not the time window, is what bounds the report size — so
    /// the window is wide enough to still contain the dictation someone is
    /// complaining about by the time they get around to reporting it.
    private static let maximumLines = 40
    private static let window = "3h"
    private static let timeout: TimeInterval = 10

    static func recent() -> String {
        let process = Process()
        // Absolute path on purpose: `log` is a common shell alias/function
        // name, and PATH here is whatever launchd handed the app.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--predicate", #"subsystem == "ai.xdlab.LocalFlow""#,
            "--last", window,
            "--style", "compact",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // don't let stderr land in the report

        do {
            try process.run()
        } catch {
            log.error("couldn't run log show: \(error.localizedDescription, privacy: .public)")
            return ""
        }

        // Read before waiting: a full pipe buffer would deadlock `waitUntilExit`.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            log.error("log show timed out after \(Int(timeout))s")
        }

        guard let output = String(data: data, encoding: .utf8) else { return "" }
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("Filtering the log data") && !$0.hasPrefix("Timestamp") }
        return lines.suffix(maximumLines).joined(separator: "\n")
    }
}
