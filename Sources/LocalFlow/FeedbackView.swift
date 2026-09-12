import SwiftUI

/// The report sheet: describe the problem, see exactly what will be sent, send
/// it.
///
/// The preview pane is not decoration. LocalFlow's whole claim is that nothing
/// leaves this Mac, and this window is the one place that stops being true —
/// so the payload is shown in full, in the same text that gets sent, before
/// any of it moves. Anything that can't be shown here doesn't belong in the
/// report.
struct FeedbackView: View {
    @EnvironmentObject private var appState: AppState
    /// Non-nil when this was opened by the "quit unexpectedly" prompt.
    let crash: CrashReport?

    @State private var diagnostics: Diagnostics?
    @State private var userDescription = ""
    @State private var includeTranscript = false
    @State private var mailFailed = false
    /// True once a draft has been handed to the mail client.
    ///
    /// Without this the button reads "Send…" forever, so clicking it again —
    /// the natural thing to do when the window stays open and nothing visibly
    /// happened — silently opens a *second* draft. Duplicate reports are worse
    /// than a missing one: they cost triage time and make one bug look like a
    /// pattern. Editing the report re-enables it, since that's a genuinely new
    /// report rather than an impatient second click.
    @State private var draftOpened = false

    private var hasTranscript: Bool { appState.recentTranscripts.first != nil }

    /// The report as it will actually be delivered, with whatever is typed
    /// right now folded in.
    private var report: Diagnostics? {
        guard var report = diagnostics else { return nil }
        report.userDescription = userDescription
        return report
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            TextEditor(text: $userDescription)
                .font(.body)
                .frame(minHeight: 84)
                .overlay(alignment: .topLeading) {
                    if userDescription.isEmpty {
                        Text(crash == nil
                             ? "What happened? What did you expect instead?"
                             : "Anything you remember about what you were doing?")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .border(Color(nsColor: .separatorColor))

            if hasTranscript {
                Toggle("Include the text of my last dictation", isOn: $includeTranscript)
                    .help("Off by default. Turn it on only if the transcript itself is the bug.")
            }

            Divider()

            Text("This is everything that gets sent:")
                .font(.subheadline.weight(.medium))

            ScrollView {
                Text(report?.fullText ?? "Collecting…")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color(nsColor: .separatorColor))
            .frame(minHeight: 200)

            if mailFailed {
                Text("No mail app answered. Use Copy or Save instead and send it however you like — the address is \(Feedback.intakeAddress).")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(16)
        .frame(width: 560, height: 640)
        // Changing what the report says makes it a different report, so let it
        // be sent again.
        .onChange(of: userDescription) { draftOpened = false }
        .onChange(of: includeTranscript) { draftOpened = false }
        .task(id: includeTranscript) {
            diagnostics = await Diagnostics.collect(
                appState: appState,
                includeTranscript: includeTranscript,
                crash: crash
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(crash == nil ? "Report an issue" : "LocalFlow quit unexpectedly")
                .font(.headline)
            Text(crash == nil
                 ? "Opens a draft in your mail app. Nothing sends until you send it."
                 : "macOS saved a crash report. Sending it is what makes the crash fixable.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Copy") {
                if let report { Feedback.copyToClipboard(report) }
            }
            Button("Save…") {
                if let report { Feedback.save(report) }
            }
            Spacer()
            if draftOpened {
                Text("Draft opened — send it from your mail app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(draftOpened ? "Draft opened" : "Send…") {
                guard let report else { return }
                let opened = Feedback.openMail(with: report)
                mailFailed = !opened
                draftOpened = opened
            }
            .keyboardShortcut(.defaultAction)
            .disabled(report == nil || draftOpened)
        }
    }
}
