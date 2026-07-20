import AppKit
import AVFoundation
import KeyboardShortcuts
import SwiftUI
import os

private let log = Logger(subsystem: "ai.xdlab.LocalFlow", category: "pipeline")

extension KeyboardShortcuts.Name {
    /// Hold to record, release to transcribe + inject.
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.option]))
    /// Tap once to start hands-free recording, tap again to stop.
    static let toggleDictation = Self("toggleDictation", default: .init(.d, modifiers: [.command, .option]))
}

/// A recent dictation kept in memory (this session only) so the text is
/// recoverable from the menu if a paste missed its target.
struct Transcript: Identifiable {
    let id = UUID()
    let text: String
    let date = Date()

    /// Single-line, clipped preview for the menu.
    var preview: String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return oneLine.count > 44 ? String(oneLine.prefix(44)) + "…" : oneLine
    }
}

@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable {
        case loadingModel
        case idle
        case recording
        case transcribing
        case cleaning
        case error(String)

        var label: String {
            switch self {
            case .loadingModel: "Loading model…"
            case .idle: "Ready"
            case .recording: "Recording…"
            case .transcribing: "Transcribing…"
            case .cleaning: "Cleaning up…"
            case .error: "Error"
            }
        }

        var symbolName: String {
            switch self {
            case .loadingModel: "hourglass"
            case .idle: "mic"
            case .recording: "mic.fill"
            case .transcribing: "waveform"
            case .cleaning: "wand.and.stars"
            case .error: "mic.slash"
            }
        }
    }

    /// How the current recording was started, so push-to-talk key-up and the
    /// hands-free toggle don't stop each other's sessions.
    private enum RecordingMode {
        case pushToTalk
        case toggle
    }

    /// Language picker choices: display name → ISO 639-1 code ("auto" = detect).
    static let languages: [(name: String, code: String)] = [
        ("Auto-detect", "auto"),
        ("English", "en"), ("中文 Chinese", "zh"), ("Español", "es"),
        ("Français", "fr"), ("Deutsch", "de"), ("日本語 Japanese", "ja"),
        ("한국어 Korean", "ko"), ("Português", "pt"), ("Русский", "ru"),
        ("Italiano", "it"), ("हिन्दी Hindi", "hi"), ("العربية Arabic", "ar"),
    ]

    /// Model picker choices: display name → WhisperKit model id. Smaller = faster,
    /// larger = more accurate. Turbo is the balanced default from PLAN.md.
    static let models: [(name: String, id: String)] = [
        ("Turbo — large-v3 (most accurate)", "large-v3-v20240930_626MB"),
        ("Small (faster)", "small"),
        ("Base (fast)", "base"),
        ("Tiny (fastest)", "tiny"),
    ]

    @Published var status: Status = .loadingModel
    /// Bumped when the user records a new shortcut so the menu bar's
    /// "Hold X to dictate" labels re-render with the current keys (they're
    /// otherwise built once and never re-read `KeyboardShortcuts.getShortcut`).
    @Published var shortcutsRevision = 0
    @Published var cleanupEnabled: Bool {
        didSet {
            UserDefaults.standard.set(cleanupEnabled, forKey: "cleanupEnabled")
            // Re-check immediately so flipping the toggle on tells you right
            // away if Ollama can't actually serve it.
            if cleanupEnabled { refreshOllamaHealth() } else { ollamaHealth = .unknown }
        }
    }
    /// Whether the optional cleanup stage can actually run. Only meaningful
    /// (and only surfaced) while `cleanupEnabled` is on.
    @Published var ollamaHealth: OllamaHealth = .unknown
    @Published var languageCode: String {
        didSet { UserDefaults.standard.set(languageCode, forKey: "languageCode") }
    }
    @Published var modelName: String {
        // didSet does NOT fire for the assignment in init(), so this only
        // triggers a reload when the user changes the picker.
        didSet {
            guard modelName != oldValue else { return }
            UserDefaults.standard.set(modelName, forKey: "modelName")
            reloadModel()
        }
    }
    @Published var overlayPosition: OverlayPosition {
        didSet {
            UserDefaults.standard.set(overlayPosition.rawValue, forKey: "overlayPosition")
            overlay.position = overlayPosition
            // Flash the pill at the new spot so the user can see it (it
            // otherwise only appears while dictating). Skip mid-session.
            if status == .idle { overlay.preview() }
        }
    }
    /// Last few dictations (newest first), in memory only — a safety net if a
    /// paste missed its target. Cleared when the app quits.
    @Published var recentTranscripts: [Transcript] = []

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let overlay = RecordingOverlay()
    private var recordingMode: RecordingMode = .pushToTalk

    init() {
        cleanupEnabled = UserDefaults.standard.bool(forKey: "cleanupEnabled")
        languageCode = UserDefaults.standard.string(forKey: "languageCode") ?? "auto"
        modelName = UserDefaults.standard.string(forKey: "modelName") ?? Transcriber.defaultModel
        overlayPosition = OverlayPosition(rawValue: UserDefaults.standard.string(forKey: "overlayPosition") ?? "") ?? .bottomCenter
        overlay.position = overlayPosition
        recorder.onLevel = { [weak self] level in
            self?.overlay.setLevel(level)
        }
        registerHotkey()
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        // Surface both permission prompts up front, then load the model.
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        TextInjector.promptForAccessibilityIfNeeded()
        guard micGranted else {
            status = .error("Microphone access denied. Grant it in System Settings → Privacy & Security → Microphone.")
            return
        }
        do {
            try await transcriber.load(modelName)
            status = .idle
        } catch {
            status = .error("Model load failed: \(error.localizedDescription)")
        }
        if cleanupEnabled { refreshOllamaHealth() }
    }

    /// Refreshes the cleanup-availability warning shown in the menu + Settings.
    func refreshOllamaHealth() {
        Task {
            let health = await OllamaCleaner.probe()
            if health != ollamaHealth {
                log.notice("ollama health: \(String(describing: health))")
            }
            ollamaHealth = health
        }
    }

    private func reloadModel() {
        log.notice("reloading model: \(self.modelName)")
        status = .loadingModel
        Task {
            do {
                try await transcriber.load(modelName)
                status = .idle
            } catch {
                log.error("model reload failed: \(error.localizedDescription)")
                status = .error("Model load failed: \(error.localizedDescription)")
            }
        }
    }

    /// Keep the newest 5 dictations in memory for the menu's Recent list.
    private func addToHistory(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentTranscripts.insert(Transcript(text: trimmed), at: 0)
        if recentTranscripts.count > 5 {
            recentTranscripts.removeLast(recentTranscripts.count - 5)
        }
    }

    /// Put a past transcript back on the clipboard so the user can paste it.
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func registerHotkey() {
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            self?.startRecording(mode: .pushToTalk)
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            self?.pushToTalkKeyUp()
        }
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) { [weak self] in
            self?.toggleDictation()
        }
    }

    /// Push-to-talk release: only stops a recording that push-to-talk started.
    private func pushToTalkKeyUp() {
        guard status == .recording, recordingMode == .pushToTalk else {
            log.notice("PTT keyUp ignored: status=\(String(describing: self.status))")
            return
        }
        stopAndTranscribe()
    }

    /// Hands-free: tap to start, tap again to stop. Ignored while busy.
    private func toggleDictation() {
        if status == .idle {
            startRecording(mode: .toggle)
        } else if status == .recording, recordingMode == .toggle {
            stopAndTranscribe()
        } else {
            log.notice("toggle ignored: status=\(String(describing: self.status))")
        }
    }

    private func startRecording(mode: RecordingMode) {
        log.notice("startRecording mode=\(String(describing: mode)) status=\(String(describing: self.status))")
        guard status == .idle else { return } // ignore key-repeat and busy states
        do {
            try recorder.start()
            recordingMode = mode
            status = .recording
            overlay.show(.listening)
        } catch {
            log.error("mic start failed: \(error.localizedDescription)")
            status = .error("Mic start failed: \(error.localizedDescription)")
        }
    }

    private func stopAndTranscribe() {
        guard status == .recording else {
            log.notice("keyUp ignored: status=\(String(describing: self.status))")
            return
        }
        let samples = recorder.stop()
        log.notice("keyUp: captured \(samples.count) samples (\(Double(samples.count) / 16_000, format: .fixed(precision: 1))s)")

        // Anything under ~0.3 s is an accidental tap; Whisper hallucinates on near-silence.
        guard samples.count > 4800 else {
            status = .idle
            overlay.hide()
            return
        }

        status = .transcribing
        overlay.show(.processing)
        let language = languageCode == "auto" ? nil : languageCode
        log.notice("transcribing: language=\(language ?? "auto")")
        Task {
            defer { overlay.hide() }
            do {
                var text = try await transcriber.transcribe(samples, language: language)
                log.notice("transcript: \(text.count) chars")
                guard !text.isEmpty else {
                    status = .idle
                    return
                }
                if cleanupEnabled, text.count > 50 {
                    status = .cleaning
                    if let cleaned = await OllamaCleaner.clean(text) {
                        text = cleaned
                        ollamaHealth = .ok
                        log.notice("cleanup ok: \(text.count) chars")
                    } else {
                        // Raw transcript still goes through — but find out WHY
                        // so the menu can say so instead of failing silently.
                        log.warning("cleanup unavailable, using raw transcript")
                        refreshOllamaHealth()
                    }
                }
                // Save before injecting, so it's recoverable even if the paste
                // misses (window switched, focus lost, Accessibility hiccup).
                addToHistory(text)
                if TextInjector.inject(text) {
                    status = .idle
                } else {
                    // Accessibility missing — CGEvent paste would silently no-op.
                    // A stale TCC entry can SHOW as granted in System Settings while
                    // the API still says untrusted: the fix is remove + re-add.
                    log.error("inject refused: Accessibility not granted")
                    status = .error("Accessibility needed: remove LocalFlow from the Accessibility list (−), then re-add it (+).")
                    TextInjector.openAccessibilitySettings()
                    // Recover automatically so the hotkey keeps working —
                    // inject() re-checks trust on every attempt anyway.
                    try? await Task.sleep(for: .seconds(4))
                    if case .error = status { status = .idle }
                }
            } catch {
                log.error("transcription failed: \(error.localizedDescription)")
                status = .error("Transcription failed: \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(3))
                if case .error = status { status = .idle }
            }
        }
    }
}
