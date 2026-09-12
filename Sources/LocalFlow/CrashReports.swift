import Foundation
import os

/// A crash report macOS already wrote for us.
///
/// LocalFlow installs no crash handler, deliberately. The two things that
/// actually kill a Swift app — a runtime trap (`fatalError`, an out-of-bounds
/// index) and a signal — arrive as SIGILL/SIGTRAP, which
/// `NSSetUncaughtExceptionHandler` never sees, so an in-process ObjC handler
/// would catch close to nothing while adding a component that runs during a
/// crash. Meanwhile macOS writes a complete, structured `.ips` report to
/// `~/Library/Logs/DiagnosticReports/` on every crash whether we ask or not.
///
/// So the job here is only to *notice* one at the next launch. That also keeps
/// the app's promise intact: nothing is uploaded in the background, and the
/// report is only read when there's a report to read.
///
/// Apple's own aggregation (Xcode → Organizer → Crashes) is not an option:
/// it only receives reports for apps distributed through the App Store or
/// TestFlight, and LocalFlow ships as a notarized zip.
struct CrashReport {
    let url: URL
    let date: Date
    /// One line naming what happened, for the prompt and the report header.
    let summary: String
    /// The full `.ips`, for the saved report. Not sent by email — it's large,
    /// and the mail path caps its body.
    let contents: String

    var fileName: String { url.lastPathComponent }
}

enum CrashReports {
    private static let log = Logger(subsystem: "ai.xdlab.LocalFlow", category: "crash")
    /// Marks the newest report we've already offered, so a decline isn't
    /// re-prompted on every launch. Stores the file's modification date.
    private static let lastSeenKey = "lastSeenCrashReport"

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// The newest LocalFlow crash report we haven't offered yet, if any.
    ///
    static func newestUnseen(now: Date = Date()) -> CrashReport? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil // no reports directory yet, which is the common case
        }

        let lastSeen = UserDefaults.standard.object(forKey: lastSeenKey) as? Date ?? .distantPast
        let candidates = entries.filter { url in
            let name = url.lastPathComponent
            guard url.pathExtension == "ips" else { return false }
            return name.hasPrefix("LocalFlow")
        }

        let newest = candidates
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else { return nil }
                return (url, date)
            }
            .filter { $0.1 > lastSeen }
            .max { $0.1 < $1.1 }

        guard let (url, date) = newest else { return nil }
        // A report older than a week is archaeology, not news — the build it
        // came from is probably gone. Mark it seen and stay quiet.
        guard now.timeIntervalSince(date) < 7 * 24 * 3600 else {
            markSeen(date: date)
            log.notice("skipping crash report older than a week: \(url.lastPathComponent, privacy: .public)")
            return nil
        }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            log.error("found crash report but couldn't read it: \(url.lastPathComponent, privacy: .public)")
            return nil
        }

        log.notice("found unreported crash: \(url.lastPathComponent, privacy: .public)")
        return CrashReport(url: url, date: date, summary: summarize(contents), contents: contents)
    }

    /// Don't offer anything at or before this report again.
    static func markSeen(date: Date) {
        UserDefaults.standard.set(date, forKey: lastSeenKey)
    }

    static func markSeen(_ report: CrashReport) {
        markSeen(date: report.date)
    }

    /// An `.ips` is a one-line JSON header followed by a JSON body. We want the
    /// few fields that say *what* happened; everything else is in the attached
    /// file. Parsing is best-effort on purpose — a summary that fails to build
    /// must not stop the report from being sent.
    private static func summarize(_ contents: String) -> String {
        guard let newline = contents.firstIndex(of: "\n") else { return "Crash report" }
        let header = String(contents[contents.startIndex..<newline])
        let body = String(contents[contents.index(after: newline)...])

        var parts: [String] = []

        // The crashing app's version lives in the header line, NOT the body —
        // and it's the field that says whether a report is even about a build
        // still in circulation, so it goes first.
        if let headerJSON = parse(header) {
            let version = headerJSON["app_version"] as? String ?? ""
            let build = headerJSON["build_version"] as? String ?? ""
            if !version.isEmpty {
                parts.append(build.isEmpty ? version : "\(version) (build \(build))")
            }
        }

        guard let bodyJSON = parse(body) else {
            parts.append("couldn't parse the .ips — full file attached")
            return parts.joined(separator: " · ")
        }
        if let exception = bodyJSON["exception"] as? [String: Any] {
            if let type = exception["type"] as? String { parts.append(type) }
            if let signal = exception["signal"] as? String { parts.append(signal) }
        }
        if let termination = bodyJSON["termination"] as? [String: Any],
           let indicator = termination["indicator"] as? String {
            parts.append(indicator)
        }
        return parts.isEmpty ? "Crash report" : parts.joined(separator: " · ")
    }

    private static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
