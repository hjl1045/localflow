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
///
/// A crash report adds a few error lines from Apple's frameworks in the crashed
/// process (`crashReason`). Those aren't ours to audit, but the same redaction
/// applies — the exception fault in the Settings crash arrived as
/// `NSGenericException: <private>` — and they're capped at three lines, from a
/// 30-second window, shown in the preview before anything is sent.
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
    /// What the crashed process logged as errors just before it died — the
    /// crash's *reason*, which the `.ips` doesn't carry. Empty when there's no
    /// crash, or the log has already rotated those lines away.
    var crashReason: [String] = []
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
        // Both are `log show` subprocesses taking a second or two each, so they
        // run side by side, off the main actor.
        async let logTail = Task.detached(priority: .userInitiated) { LogTail.recent() }.value
        async let crashReason = Task.detached(priority: .userInitiated) {
            crash.map(LogTail.crashReason(for:)) ?? []
        }.value

        return await Diagnostics(
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
            crashReason: crashReason,
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
        guard !trimmed.isEmpty else { return "LocalFlow \(appVersion) report" }
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
            // Reason before location: for the Settings crash of 2026-09-12 the
            // one AppKit line below named the bug outright, while the stack
            // only said "somewhere in Auto Layout".
            out += "**Logged just before it crashed**\n\n"
            out += crashReason.isEmpty
                ? "_Nothing — no errors in the 30s before the crash, or the log has rotated._\n\n"
                : "```\n\(crashReason.joined(separator: "\n"))\n```\n\n"
            if !crash.stack.isEmpty {
                out += "**Where**\n\n```\n\(crash.stack.joined(separator: "\n"))\n```\n\n"
            }
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
        let output = run([
            "show",
            "--predicate", #"subsystem == "ai.xdlab.LocalFlow""#,
            "--last", window,
            "--style", "compact",
        ])
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("Filtering the log data") && !$0.hasPrefix("Timestamp") }
        return lines.suffix(maximumLines).joined(separator: "\n")
    }

    /// Lines kept for a crash's reason, and how much of each.
    private static let maximumReasonLines = 3
    private static let maximumReasonLength = 360
    /// How far back from the crash to look. A crash's own exception message
    /// lands well under a second before it (0.2s for the Settings crash).
    private static let reasonWindow: TimeInterval = 30

    /// The error and fault lines the crashed process wrote in its last 30
    /// seconds — from Apple's frameworks too, not only LocalFlow's own
    /// subsystem, because that's where an exception's message goes.
    ///
    /// Selecting by pid keeps out every other process, including the relaunched
    /// LocalFlow that's now filing the report. The lines are shown in the
    /// report preview before anything is sent.
    static func crashReason(for crash: CrashReport) -> [String] {
        guard let pid = crash.pid, let capturedAt = crash.capturedAt else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss" // `log show` reads local time
        let output = run([
            "show",
            "--start", formatter.string(from: capturedAt.addingTimeInterval(-reasonWindow)),
            "--end", formatter.string(from: capturedAt.addingTimeInterval(2)),
            "--predicate", "processIdentifier == \(pid) AND (messageType == error OR messageType == fault)",
            "--style", "compact",
        ])
        return reasonLines(from: output)
    }

    /// Compact-style `log show` output → one line per entry.
    ///
    /// An entry can span several lines: AppKit's layout-loop message continues
    /// with the window and its size on the next line, and an exception entry is
    /// followed by a whole backtrace. Continuations are joined onto their entry;
    /// backtrace frames and bare brackets are dropped (the stack section already
    /// says where). Repeats — AppKit logs the same message twice — are kept once.
    static func reasonLines(from output: String) -> [String] {
        let header = try! NSRegularExpression(
            pattern: #"^\d{4}-\d{2}-\d{2} (\d{2}:\d{2}:\d{2}\.\d{3}) (\w+)\s+\S+\[\d+:[0-9a-f]+\] (?:(\[[^\]]+\]) )?(.*)$"#
        )
        let frame = try! NSRegularExpression(pattern: #"^\s*\d+\s+\S+\s+0x[0-9a-f]+ "#)

        var entries: [(prefix: String, message: String)] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let range = NSRange(raw.startIndex..., in: raw)
            if let match = header.firstMatch(in: raw, range: range) {
                func group(_ i: Int) -> String {
                    Range(match.range(at: i), in: raw).map { String(raw[$0]) } ?? ""
                }
                let prefix = [group(1), group(2), group(3)].filter { !$0.isEmpty }.joined(separator: " ")
                entries.append((prefix, group(4).trimmingCharacters(in: .whitespaces)))
            } else if !entries.isEmpty,
                      frame.firstMatch(in: raw, range: range) == nil,
                      !["(", ")"].contains(raw.trimmingCharacters(in: .whitespaces)) {
                entries[entries.count - 1].message += " " + raw.trimmingCharacters(in: .whitespaces)
            }
        }

        var seen = Set<String>()
        let unique = entries.filter { entry in
            guard entry.message.count > 2 else { return false } // the "(" that opens a backtrace
            return seen.insert(String(entry.message.prefix(120))).inserted
        }
        return unique.suffix(maximumReasonLines).map { entry in
            let line = "\(entry.prefix) \(entry.message)"
            return line.count > maximumReasonLength ? String(line.prefix(maximumReasonLength)) + "…" : line
        }
    }

    private static func run(_ arguments: [String]) -> String {
        let process = Process()
        // Absolute path on purpose: `log` is a common shell alias/function
        // name, and PATH here is whatever launchd handed the app.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = arguments
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

        return String(data: data, encoding: .utf8) ?? ""
    }
}
