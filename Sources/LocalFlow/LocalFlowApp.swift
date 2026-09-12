import AppKit
import SwiftUI
import KeyboardShortcuts

@main
enum Main {
    /// `LocalFlow --transcribe file.wav [--language xx] [--clean]` runs a
    /// headless pipeline test (no mic/hotkey/UI) and exits — used to verify
    /// the ASR + cleanup stages end-to-end. Without flags, launches the
    /// menu bar app.
    /// Flags the headless paths below understand. Anything else starting with
    /// `--` is a typo or a flag that used to exist, and falling through to
    /// `LocalFlowApp.main()` would silently launch the menu bar app instead of
    /// saying so — which is exactly what happened when `--check-updates` was
    /// removed along with the companion app.
    private static let knownFlags: Set<String> = [
        "--diagnostics", "--diagnostics-mail",
        "--transcribe", "--language", "--model", "--clean",
    ]

    static func main() async {
        let args = CommandLine.arguments
        let unknown = args.dropFirst().filter { $0.hasPrefix("--") && !knownFlags.contains($0) }
        if !unknown.isEmpty {
            print("Unknown option\(unknown.count > 1 ? "s" : ""): \(unknown.joined(separator: ", "))")
            print("")
            print("Usage:")
            print("  LocalFlow                                          launch the menu bar app")
            print("  LocalFlow --transcribe FILE [--language xx]")
            print("                              [--model NAME] [--clean]")
            print("  LocalFlow --diagnostics                            print a bug report")
            print("  LocalFlow --diagnostics-mail                       print the emailed form of one")
            exit(2)
        }
        if args.contains("--diagnostics") || args.contains("--diagnostics-mail") {
            let state = await MainActor.run { AppState(live: false) }
            let crash = CrashReports.newestUnseen()
            let report = await Diagnostics.collect(appState: state, crash: crash)
            if args.contains("--diagnostics-mail") {
                let body = Feedback.mailBody(for: report)
                print("To: \(Feedback.intakeAddress)")
                print("Subject: \(report.subject)")
                print("Body bytes: \(body.count)")
                if let url = Feedback.mailtoURL(for: report) {
                    print("mailto URL length: \(url.absoluteString.count)")
                } else {
                    print("FAILED: could not build a mailto URL")
                    exit(1)
                }
                print("---")
                print(body)
            } else {
                print(report.fullText)
            }
            exit(0)
        }
        if let flagIndex = args.firstIndex(of: "--transcribe"), args.count > flagIndex + 1 {
            var language: String?
            if let langIndex = args.firstIndex(of: "--language"), args.count > langIndex + 1 {
                language = args[langIndex + 1]
            }
            var model = Transcriber.defaultModel
            if let modelIndex = args.firstIndex(of: "--model"), args.count > modelIndex + 1 {
                model = args[modelIndex + 1]
            }
            do {
                let transcriber = Transcriber()
                print("Loading \(model)…")
                let loadStart = Date()
                try await transcriber.load(model)
                print(String(format: "Model loaded in %.1fs", -loadStart.timeIntervalSinceNow))

                let transcribeStart = Date()
                var text = try await transcriber.transcribe(path: args[flagIndex + 1], language: language)
                print(String(format: "Transcribed in %.2fs: %@", -transcribeStart.timeIntervalSinceNow, text))

                if args.contains("--clean") {
                    let cleanStart = Date()
                    if let cleaned = await OllamaCleaner.clean(text) {
                        text = cleaned
                        print(String(format: "Cleaned in %.2fs: %@", -cleanStart.timeIntervalSinceNow, text))
                    } else {
                        let health = await OllamaCleaner.probe()
                        print("Cleanup unavailable: \(health.warning ?? "Ollama returned nothing usable")")
                        if let hint = health.fixHint { print("  \(hint)") }
                    }
                }
                exit(0)
            } catch {
                print("FAILED: \(error)")
                exit(1)
            }
        }
        LocalFlowApp.main()
    }
}

/// Settings for a menu-bar (`.accessory`) app.
///
/// SwiftUI's `Settings` scene is unusable here: in an accessory app its window
/// never enters `NSApp.windows` controllably and never becomes *key*, so every
/// control renders disabled (grayed) and `KeyboardShortcuts.Recorder` can't
/// capture keys. Instead we host `SettingsView` in a plain AppKit `NSWindow` we
/// own outright — it's a normal titled window that becomes key and enables its
/// fields. While it's open we promote the app to `.regular` (a focusable window
/// with a transient Dock icon), reverting to `.accessory` when it closes.
///
/// `showSettings` is **static on purpose:** SwiftUI's
/// `@NSApplicationDelegateAdaptor` installs its *own* object as `NSApp.delegate`
/// that merely forwards to this instance, so `NSApp.delegate as? AppDelegate`
/// fails and can't reach an instance method. A static entry point, called
/// straight from the menu button, sidesteps that.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let settingsTitle = "LocalFlow Settings"
    private static let feedbackTitle = "Report an Issue"
    private static var settingsWindow: NSWindow?
    private static var feedbackWindow: NSWindow?
    /// Windows we own, whose closing should drop the Dock icon again.
    private static var ownedTitles: Set<String> { [settingsTitle, feedbackTitle] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @MainActor
    static func showSettings(appState: AppState) {
        NSApp.setActivationPolicy(.regular)
        // Ollama may have been started (or stopped) since the last check.
        if appState.cleanupEnabled { appState.refreshOllamaHealth() }

        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(appState))
            window = NSWindow(contentViewController: hosting)
            window.title = settingsTitle
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false // reuse it across opens
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens the report window. `crash` is non-nil when a crash report from the
    /// previous run prompted it, which changes the window's framing but not the
    /// flow: nothing is sent until the reporter sends it.
    @MainActor
    static func showFeedback(appState: AppState, crash: CrashReport? = nil) {
        NSApp.setActivationPolicy(.regular)

        // Rebuilt each time rather than reused: the report is a snapshot of
        // machine state, and a stale window would show a stale one. (Settings
        // is reused because its content is live-bound to AppState.)
        if let existing = feedbackWindow {
            existing.close()
        }
        let hosting = NSHostingController(
            rootView: FeedbackView(crash: crash).environmentObject(appState)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = feedbackTitle
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        feedbackWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the report window. Called once the mail draft exists, because at
    /// that point the window has nothing left to do — see FeedbackView.
    ///
    /// Deferred to the next main-loop turn on purpose: the caller is a button
    /// *inside* this window, and tearing the window down while its own action
    /// is still on the stack is how you get a use-after-free. The static
    /// reference is deliberately not cleared either — `showFeedback` replaces
    /// it on the next open, and dropping the last strong reference here would
    /// release the window mid-action even with `isReleasedWhenClosed = false`.
    @MainActor
    static func closeFeedback() {
        let window = feedbackWindow
        DispatchQueue.main.async { window?.close() }
    }

    /// The "your last run crashed" prompt. A short alert rather than the report
    /// window itself, because the app launches at login — an unrequested 640pt
    /// window every time you log in is worse than the bug it's reporting.
    @MainActor
    static func presentCrashPrompt(appState: AppState, crash: CrashReport) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "LocalFlow quit unexpectedly"
        alert.informativeText = """
        macOS saved a crash report from the last run (\(crash.summary)).

        Sending it is what makes the crash fixable — you'll see the whole report and send it from your own mail app.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Report…")
        alert.addButton(withTitle: "Ignore")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        showFeedback(appState: appState, crash: crash)
    }

    /// Drop the transient Dock icon again once the last window we own closes.
    ///
    /// The visibility re-check matters now that there are two such windows:
    /// closing the report window while Settings is still open must not demote
    /// the app back to `.accessory`, or Settings loses focus and its shortcut
    /// recorder stops accepting keys — the exact bug the `.regular` promotion
    /// exists to avoid.
    @objc private func windowWillClose(_ note: Notification) {
        guard let closing = note.object as? NSWindow, Self.ownedTitles.contains(closing.title) else { return }
        DispatchQueue.main.async {
            let stillOpen = NSApp.windows.contains {
                $0 !== closing && $0.isVisible && Self.ownedTitles.contains($0.title)
            }
            if !stillOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

struct LocalFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.status.symbolName)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Text(appState.status.label)
        if case .error(let message) = appState.status {
            Text(message)
        }
        Divider()
        Toggle("AI Cleanup (Ollama)", isOn: $appState.cleanupEnabled)
        // The toggle can be ON while cleanup silently no-ops (server down, model
        // not pulled). Say so here rather than letting it look like it's working.
        if appState.cleanupEnabled, let warning = appState.ollamaHealth.warning {
            Text("⚠︎ \(warning)")
        }
        if let shortcut = KeyboardShortcuts.getShortcut(for: .pushToTalk) {
            Text("Hold \(shortcut.description) to dictate")
        }
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation) {
            Text("Tap \(shortcut.description) for hands-free")
        }
        if !appState.recentTranscripts.isEmpty {
            Divider()
            Menu("Recent transcripts") {
                ForEach(appState.recentTranscripts) { transcript in
                    Button(menuLabel(transcript)) {
                        appState.copyToClipboard(transcript.text)
                    }
                }
                Divider()
                Button("Clear recent") { appState.recentTranscripts.removeAll() }
            }
        }
        Divider()
        // A plain SettingsLink opens the window but, in an LSUIElement app, it
        // stays unfocused so the shortcut recorder can't capture keys. The app
        // delegate promotes us to a regular app while Settings is open.
        Button("Settings…") {
            AppDelegate.showSettings(appState: appState)
        }
        Button("Report an issue…") {
            AppDelegate.showFeedback(appState: appState)
        }
        Divider()
        Button("Quit LocalFlow") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func menuLabel(_ transcript: Transcript) -> String {
        "\(transcript.preview)  ·  \(ago(transcript.date))"
    }

    private func ago(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Push-to-talk (hold):", name: .pushToTalk) { _ in
                appState.shortcutsRevision += 1
            }
            KeyboardShortcuts.Recorder("Hands-free (tap on/off):", name: .toggleDictation) { _ in
                appState.shortcutsRevision += 1
            }
            Picker("Language:", selection: $appState.languageCode) {
                ForEach(AppState.languages, id: \.code) { language in
                    Text(language.name).tag(language.code)
                }
            }
            Picker("Model:", selection: $appState.modelName) {
                ForEach(AppState.models, id: \.id) { model in
                    Text(model.name).tag(model.id)
                }
            }
            Picker("Listening bar:", selection: $appState.overlayPosition) {
                ForEach(OverlayPosition.allCases) { pos in
                    Text(pos.displayName).tag(pos)
                }
            }
            Toggle("Clean up transcript with Ollama (\(OllamaCleaner.model))", isOn: $appState.cleanupEnabled)
            if appState.cleanupEnabled, let warning = appState.ollamaHealth.warning {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warning)
                        if let hint = appState.ollamaHealth.fixHint {
                            Text(hint).font(.system(.caption, design: .monospaced))
                        }
                    }
                    Spacer()
                    Button("Re-check") { appState.refreshOllamaHealth() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    LoginItem.setEnabled(newValue)
                    launchAtLogin = LoginItem.isEnabled // re-sync if registration failed
                }
            Text("Hold the push-to-talk key, or tap the hands-free key to start and again to stop. Text is typed at your cursor. Smaller models are faster but less accurate.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460)
    }
}
