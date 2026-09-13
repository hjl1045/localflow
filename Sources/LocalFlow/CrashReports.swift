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
    /// The top of the stack that crashed, one frame per line: the thrown
    /// exception's backtrace when the `.ips` has one, else the crashing thread.
    /// Unlike `contents`, this travels in the email — it says *where*.
    let stack: [String]
    /// Which process crashed and when. Together they pick out that process's
    /// own log lines from just before it died, which is where the *reason* is —
    /// an AppKit exception message never makes it into the `.ips`.
    let pid: Int?
    let capturedAt: Date?
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

        guard let report = load(url, date: date) else { return nil }
        log.notice("found unreported crash: \(url.lastPathComponent, privacy: .public)")
        return report
    }

    /// One specific `.ips`, whether or not it has been offered. The launch
    /// check goes through here, and so does `--diagnostics --crash-file`, which
    /// is how a report's rendering gets checked against a real crash.
    static func load(_ url: URL, date: Date? = nil) -> CrashReport? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            log.error("found crash report but couldn't read it: \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        let modified = date
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date()

        let (headerJSON, bodyJSON) = split(contents)
        return CrashReport(
            url: url,
            date: modified,
            summary: summarize(header: headerJSON, body: bodyJSON),
            stack: bodyJSON.map(stack(from:)) ?? [],
            pid: bodyJSON?["pid"] as? Int,
            // Not the file's date: macOS writes the .ips well after the crash
            // (34s later, for the Settings crash of 2026-09-12), and the log
            // window has to be anchored on the moment the process died.
            capturedAt: (bodyJSON?["captureTime"] as? String).flatMap(parseCaptureTime),
            contents: contents
        )
    }

    /// Don't offer anything at or before this report again.
    static func markSeen(date: Date) {
        UserDefaults.standard.set(date, forKey: lastSeenKey)
    }

    static func markSeen(_ report: CrashReport) {
        markSeen(date: report.date)
    }

    /// An `.ips` is a one-line JSON header followed by a JSON body. Parsing is
    /// best-effort throughout — a report whose details fail to parse must still
    /// be sendable, since the full file travels with the saved report.
    private static func split(_ contents: String) -> (header: [String: Any]?, body: [String: Any]?) {
        guard let newline = contents.firstIndex(of: "\n") else { return (nil, nil) }
        return (
            parse(String(contents[contents.startIndex..<newline])),
            parse(String(contents[contents.index(after: newline)...]))
        )
    }

    /// The few fields that say *what* happened.
    private static func summarize(header headerJSON: [String: Any]?, body bodyJSON: [String: Any]?) -> String {
        var parts: [String] = []

        // The crashing app's version lives in the header line, NOT the body —
        // and it's the field that says whether a report is even about a build
        // still in circulation, so it goes first.
        if let headerJSON {
            let version = headerJSON["app_version"] as? String ?? ""
            let build = headerJSON["build_version"] as? String ?? ""
            if !version.isEmpty {
                parts.append(build.isEmpty ? version : "\(version) (build \(build))")
            }
        }

        guard let bodyJSON else {
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

    /// Frames kept for the report. Enough to get past AppKit's crash machinery
    /// into the code that was running; the rest is in the full file.
    private static let maximumFrames = 8

    /// `AppKit  -[NSView updateConstraints…]`, or `LocalFlow +0x1a2b` when the
    /// frame has no symbol. Deep recursion — which is what a layout loop looks
    /// like — collapses to one line with a count instead of eating the budget.
    private static func stack(from body: [String: Any]) -> [String] {
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let exception = body["lastExceptionBacktrace"] as? [[String: Any]] ?? []
        var frames = exception
        if frames.isEmpty,
           let threads = body["threads"] as? [[String: Any]],
           let faulting = body["faultingThread"] as? Int,
           threads.indices.contains(faulting) {
            frames = threads[faulting]["frames"] as? [[String: Any]] ?? []
        }

        var lines: [(text: String, count: Int)] = []
        for frame in frames {
            let index = frame["imageIndex"] as? Int ?? -1
            let image = images.indices.contains(index) ? (images[index]["name"] as? String ?? "???") : "???"
            let text: String
            if let symbol = frame["symbol"] as? String {
                text = "\(image)  \(symbol)"
            } else {
                text = "\(image) +0x\(String(frame["imageOffset"] as? Int ?? 0, radix: 16))"
            }
            if let last = lines.last, last.text == text {
                lines[lines.count - 1].count += 1
            } else {
                if lines.count == maximumFrames { break }
                lines.append((text, 1))
            }
        }
        return lines.map { line in
            let clipped = line.text.count > 110 ? String(line.text.prefix(110)) + "…" : line.text
            return line.count > 1 ? "\(clipped)  ×\(line.count)" : clipped
        }
    }

    /// `2026-09-12 22:40:06.6152 -0700`. Second precision is plenty: this only
    /// anchors a log window.
    private static func parseCaptureTime(_ string: String) -> Date? {
        let whole = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: whole)
    }

    private static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
