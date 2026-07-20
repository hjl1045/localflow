import AppKit
import SwiftUI
import KeyboardShortcuts

@main
enum Main {
    /// `LocalFlow --transcribe file.wav [--language xx] [--clean]` runs a
    /// headless pipeline test (no mic/hotkey/UI) and exits — used to verify
    /// the ASR + cleanup stages end-to-end. Without flags, launches the
    /// menu bar app.
    static func main() async {
        let args = CommandLine.arguments
        // Same resolution + launch the "Check for updates…" menu item performs,
        // reachable without clicking a menu — that's how it gets tested.
        if args.contains("--check-updates") {
            guard let url = UpdateCheck.companionURL() else {
                print("FAILED: companion app not installed — run `make install`")
                exit(1)
            }
            print("Companion app: \(url.path)")
            await MainActor.run { UpdateCheck.launch() }
            try? await Task.sleep(for: .seconds(2)) // let the launch complete
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
    private static var settingsWindow: NSWindow?

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

    /// Drop the transient Dock icon again once the settings window closes.
    @objc private func windowWillClose(_ note: Notification) {
        guard let closing = note.object as? NSWindow, closing.title == Self.settingsTitle else { return }
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
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
        // Opens the companion app, which runs the model/dependency check in a
        // Terminal window. Lives here because that's where you look for it.
        Button("Check for updates…") {
            UpdateCheck.launch()
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
