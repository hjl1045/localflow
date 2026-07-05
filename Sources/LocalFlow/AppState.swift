import AppKit
import AVFoundation
import KeyboardShortcuts
import SwiftUI
import os

private let log = Logger(subsystem: "ai.xdlab.LocalFlow", category: "pipeline")

extension KeyboardShortcuts.Name {
    /// Hold to record, release to transcribe + inject.
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.option]))
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
            case .loadingModel: "Loading \(Transcriber.modelName)…"
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

    /// Language picker choices: display name → ISO 639-1 code ("auto" = detect).
    static let languages: [(name: String, code: String)] = [
        ("Auto-detect", "auto"),
        ("English", "en"), ("中文 Chinese", "zh"), ("Español", "es"),
        ("Français", "fr"), ("Deutsch", "de"), ("日本語 Japanese", "ja"),
        ("한국어 Korean", "ko"), ("Português", "pt"), ("Русский", "ru"),
        ("Italiano", "it"), ("हिन्दी Hindi", "hi"), ("العربية Arabic", "ar"),
    ]

    @Published var status: Status = .loadingModel
    @Published var cleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(cleanupEnabled, forKey: "cleanupEnabled") }
    }
    @Published var languageCode: String {
        didSet { UserDefaults.standard.set(languageCode, forKey: "languageCode") }
    }

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let overlay = RecordingOverlay()

    init() {
        cleanupEnabled = UserDefaults.standard.bool(forKey: "cleanupEnabled")
        languageCode = UserDefaults.standard.string(forKey: "languageCode") ?? "auto"
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
            try await transcriber.load()
            status = .idle
        } catch {
            status = .error("Model load failed: \(error.localizedDescription)")
        }
    }

    private func registerHotkey() {
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            self?.startRecording()
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            self?.stopAndTranscribe()
        }
    }

    private func startRecording() {
        log.notice("keyDown: status=\(String(describing: self.status))")
        guard status == .idle else { return } // ignore key-repeat and busy states
        do {
            try recorder.start()
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
                        log.notice("cleanup ok: \(text.count) chars")
                    } else {
                        log.warning("cleanup unavailable, using raw transcript")
                    }
                }
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
