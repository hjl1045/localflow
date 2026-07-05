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
                        print("Cleanup unavailable (is Ollama running?)")
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

/// In an `LSUIElement` (`.accessory`) app the Settings window never becomes
/// truly *key*, so `KeyboardShortcuts.Recorder` silently swallows keypresses
/// (you can't change the shortcut) and pickers are flaky. We briefly promote
/// the app to `.regular` while Settings is open — the window then becomes key
/// and the recorder works — and drop back to `.accessory` when it closes, so
/// there's no lingering Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    /// Open Settings and make it interactive. Called from the menu.
    @MainActor
    func showSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Ventura+ selector; fall back to the pre-Ventura name just in case.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let closing = note.object as? NSWindow, isSettingsWindow(closing) else { return }
        // Recount once the window is actually gone; revert to accessory when no
        // Settings window remains, dropping the transient Dock icon.
        DispatchQueue.main.async {
            let stillOpen = NSApp.windows.contains {
                $0 !== closing && self.isSettingsWindow($0) && $0.isVisible
            }
            if !stillOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// The Settings window is a normal titled window; the recording overlay is a
    /// borderless `NSPanel` and the menu-bar extra has no standard window, so
    /// neither of those trips the policy flip.
    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled)
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

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
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
        if let shortcut = KeyboardShortcuts.getShortcut(for: .pushToTalk) {
            Text("Hold \(shortcut.description) to dictate")
        }
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation) {
            Text("Tap \(shortcut.description) for hands-free")
        }
        // A plain SettingsLink opens the window but, in an LSUIElement app, it
        // stays unfocused so the shortcut recorder can't capture keys. The app
        // delegate promotes us to a regular app while Settings is open.
        Button("Settings…") {
            (NSApp.delegate as? AppDelegate)?.showSettings()
        }
        Divider()
        Button("Quit LocalFlow") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Push-to-talk (hold):", name: .pushToTalk)
            KeyboardShortcuts.Recorder("Hands-free (tap on/off):", name: .toggleDictation)
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
            Toggle("Clean up transcript with Ollama (\(OllamaCleaner.model))", isOn: $appState.cleanupEnabled)
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
