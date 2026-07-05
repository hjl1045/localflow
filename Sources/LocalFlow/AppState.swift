import AppKit
import AVFoundation
import KeyboardShortcuts
import SwiftUI

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
        guard status == .idle else { return } // ignore key-repeat and busy states
        do {
            try recorder.start()
            status = .recording
            overlay.show(.listening)
        } catch {
            status = .error("Mic start failed: \(error.localizedDescription)")
        }
    }

    private func stopAndTranscribe() {
        guard status == .recording else { return }
        let samples = recorder.stop()

        // Anything under ~0.3 s is an accidental tap; Whisper hallucinates on near-silence.
        guard samples.count > 4800 else {
            status = .idle
            overlay.hide()
            return
        }

        status = .transcribing
        overlay.show(.processing)
        let language = languageCode == "auto" ? nil : languageCode
        Task {
            defer { overlay.hide() }
            do {
                var text = try await transcriber.transcribe(samples, language: language)
                guard !text.isEmpty else {
                    status = .idle
                    return
                }
                if cleanupEnabled, text.count > 50 {
                    status = .cleaning
                    if let cleaned = await OllamaCleaner.clean(text) {
                        text = cleaned
                    } // on nil (Ollama down/timeout) fall back to the raw transcript
                }
                TextInjector.inject(text)
                status = .idle
            } catch {
                status = .error("Transcription failed: \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(3))
                if case .error = status { status = .idle }
            }
        }
    }
}
