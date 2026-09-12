import AppKit
import os

/// Delivery for a `Diagnostics` report.
///
/// ## Why email, and not the Linear API
///
/// Reports become issues in Linear, but the app never talks to Linear. A
/// Linear API key grants read/write to an entire workspace and there is no
/// write-only intake token, so a key embedded in a public, MIT-licensed binary
/// would hand the whole workspace to anyone who ran `strings` on the download.
/// A relay service holding the key would work — that's what Echo Story does —
/// but it means running a service and opening a public endpoint for an app
/// that currently makes no off-machine network calls at all.
///
/// Mailing a team intake address costs neither. Linear turns the mail into an
/// issue with the sender's address attached, so a report is answerable; the
/// app holds no credential; and the reporter sees the exact payload in their
/// own mail client before anything sends, which is the only send path
/// consistent with "nothing leaves this Mac."
enum Feedback {
    private static let log = Logger(subsystem: "ai.xdlab.LocalFlow", category: "feedback")

    /// Where a report is mailed, chosen by what kind of report it is.
    ///
    /// An email carries only a subject and a body — there is no field that says
    /// "project: LocalFlow, label: Bug". Linear's one hook for attaching
    /// properties to incoming mail is a **team template with its own address**,
    /// so the address itself is the signal, and the app picks it.
    ///
    /// These are public by necessity — they ship inside the app. That's an
    /// accepted, reversible risk rather than an oversight: each local part
    /// carries a random token, so they aren't guessable, and if one is ever
    /// scraped and spammed, regenerating it in Linear invalidates the old one.
    /// Rotation procedure: `docs/FEEDBACK.md`.
    static func intakeAddress(for diagnostics: Diagnostics) -> String {
        diagnostics.crash == nil ? feedbackIntakeAddress : crashIntakeAddress
    }

    /// Template "LocalFlow crash report" → project LocalFlow, label `Bug`.
    static let crashIntakeAddress = "localflow-crash-report-7977588461c1@intake.linear.app"

    /// Still the plain *team* intake address, which files into the team with no
    /// project and no label. Its template ("LocalFlow feedback" → project
    /// LocalFlow, label `feedback › general`) exists, but enabling its email
    /// address is a settings toggle that hasn't been flipped yet. Swap this one
    /// line when it is — nothing else needs to change.
    static let feedbackIntakeAddress = "the-autonomes-84537e82dae6@intake.linear.app"

    /// Mail clients and `NSWorkspace.open` both get unreliable with very long
    /// URLs, and a report that silently fails to open is worse than a short
    /// one. The full text always remains available via Copy and Save.
    private static let maximumMailBody = 4000

    // MARK: - Paths

    /// Opens the user's mail client with the report prefilled. Returns false if
    /// the URL couldn't be built or no mail client handled it — the caller
    /// falls back to offering Copy/Save.
    @MainActor
    static func openMail(with diagnostics: Diagnostics) -> Bool {
        guard let url = mailtoURL(for: diagnostics) else {
            log.error("couldn't build a mailto URL for the report")
            return false
        }
        let opened = NSWorkspace.shared.open(url)
        log.notice("feedback mail draft opened: \(opened)")
        return opened
    }

    static func mailtoURL(for diagnostics: Diagnostics) -> URL? {
        let body = mailBody(for: diagnostics)
        guard let subject = encode(diagnostics.subject), let encodedBody = encode(body) else {
            return nil
        }
        return URL(string: "mailto:\(intakeAddress(for: diagnostics))?subject=\(subject)&body=\(encodedBody)")
    }

    @MainActor
    static func copyToClipboard(_ diagnostics: Diagnostics) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.fullText, forType: .string)
        log.notice("report copied to clipboard")
    }

    /// Saves the full report — crash file included — so it can be attached to
    /// an email or pasted somewhere later.
    @MainActor
    static func save(_ diagnostics: Diagnostics) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName(for: diagnostics)
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.message = "Save the full LocalFlow report, including the crash file if there is one."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try diagnostics.fullText.write(to: url, atomically: true, encoding: .utf8)
            log.notice("report saved")
        } catch {
            log.error("saving the report failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Couldn’t save the report"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Body shaping

    /// The email body: the report without the full `.ips` (too large for a
    /// URL), trimmed to fit by dropping the oldest log lines first — the ones
    /// least likely to describe what went wrong.
    static func mailBody(for diagnostics: Diagnostics) -> String {
        var trimmed = diagnostics
        var body = trimmed.body(includeFullCrash: false)
        guard body.count > maximumMailBody else { return body }

        var lines = trimmed.logTail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var dropped = 0
        // Stop at one line rather than zero: an empty tail would make the body
        // claim there were no log lines at all, which is the opposite of true.
        while body.count > maximumMailBody, lines.count > 1 {
            lines.removeFirst()
            dropped += 1
            trimmed.logTail = lines.joined(separator: "\n")
            body = trimmed.body(includeFullCrash: false)
        }

        if body.count > maximumMailBody {
            body = String(body.prefix(maximumMailBody))
        }
        let note = dropped == 0
            ? "Trimmed to fit an email."
            : "Trimmed to fit an email — \(dropped) older log line(s) dropped."
        return body + "\n_\(note) Ask the reporter for the saved report for the full log._\n"
    }

    private static func suggestedFileName(for diagnostics: Diagnostics) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = formatter.string(from: diagnostics.generatedAt)
        let kind = diagnostics.crash == nil ? "feedback" : "crash"
        return "LocalFlow-\(kind)-\(stamp).txt"
    }

    /// RFC 3986 unreserved characters only. Deliberately stricter than
    /// `URLComponents`, which leaves `+` unescaped — several mail clients read
    /// a literal `+` in a body as a space, which would quietly mangle reports.
    private static func encode(_ string: String) -> String? {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return string.addingPercentEncoding(withAllowedCharacters: unreserved)
    }
}
