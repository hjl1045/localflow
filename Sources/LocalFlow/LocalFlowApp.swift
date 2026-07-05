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
            do {
                let transcriber = Transcriber()
                print("Loading \(Transcriber.modelName)…")
                let loadStart = Date()
                try await transcriber.load()
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

struct LocalFlowApp: App {
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
        } else {
            Text("No push-to-talk key set")
        }
        SettingsLink {
            Text("Settings…")
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

    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Push-to-talk key:", name: .pushToTalk)
            Picker("Language:", selection: $appState.languageCode) {
                ForEach(AppState.languages, id: \.code) { language in
                    Text(language.name).tag(language.code)
                }
            }
            Toggle("Clean up transcript with Ollama (\(OllamaCleaner.model))", isOn: $appState.cleanupEnabled)
            Text("Hold the key, speak, release. Text is typed at your cursor.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }
}
