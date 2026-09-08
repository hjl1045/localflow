import Foundation
import WhisperKit
import os

private let log = Logger(subsystem: "ai.xdlab.LocalFlow", category: "transcribe")

/// Wraps WhisperKit. Loads the model once (auto-downloading it on first run)
/// and serializes transcription requests.
actor Transcriber {
    /// Compressed Whisper Large-v3-Turbo (~0.6 GB) — the balanced
    /// latency/accuracy pick (see docs/MODEL-UPDATES.md). WhisperKit fuzzy-matches these
    /// names against the argmaxinc/whisperkit-coreml model repo.
    static let defaultModel = "large-v3-v20240930_626MB"

    private var whisperKit: WhisperKit?
    private(set) var currentModel: String?

    /// Loads `model`, downloading + compiling it on first use. A no-op if
    /// that model is already loaded; otherwise it swaps the active model.
    func load(_ model: String = defaultModel) async throws {
        if whisperKit != nil, currentModel == model { return }
        whisperKit = nil
        // prewarm runs the CoreML→ANE specialization now (during the visible
        // "Loading model…" phase) instead of stalling the user's FIRST
        // dictation by ~60s. Every dictation afterwards is warm and fast.
        let config = WhisperKitConfig(model: model, prewarm: true, load: true)
        whisperKit = try await WhisperKit(config)
        currentModel = model
    }

    /// Headless test path: transcribe an audio file directly.
    /// `language` is an ISO 639-1 code ("en", "es", …) or nil to auto-detect.
    ///
    /// Loads the file to samples and hands off to the array path rather than
    /// calling WhisperKit's `audioPath:` overload — which does the same load
    /// internally — so the headless path exercises *exactly* what the
    /// microphone does, silence trimming included. A test path that skips a
    /// stage can't verify it.
    func transcribe(path: String, language: String? = nil) async throws -> String {
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        return try await transcribe(samples, language: language)
    }

    func transcribe(_ samples: [Float], language: String? = nil) async throws -> String {
        guard let whisperKit else {
            throw NSError(domain: "LocalFlow", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Model not loaded yet."
            ])
        }
        let audio = SilenceTrimmer.trimTrailingSilence(samples)
        if audio.count < samples.count {
            let seconds = Double(samples.count - audio.count) / AudioRecorder.targetSampleRate
            log.notice("trimmed \(seconds, format: .fixed(precision: 2))s of trailing silence")
        }
        let results = try await whisperKit.transcribe(
            audioArray: audio,
            decodeOptions: Self.decodingOptions(language: language)
        )
        return Self.joinedText(results)
    }

    /// large-v3-turbo is natively multilingual (~100 languages); we either
    /// pin the language or let the model detect it from the audio.
    private static func decodingOptions(language: String?) -> DecodingOptions {
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = language
        options.detectLanguage = language == nil
        return options
    }

    /// Both transcribe paths funnel through here, so the non-speech annotations
    /// Whisper adds ([BLANK_AUDIO] for the silent tail of a push-to-talk take,
    /// [MUSIC], laughter…) are stripped once, before any caller sees the text.
    private static func joinedText(_ results: [TranscriptionResult]) -> String {
        let joined = results
            .map(\.text)
            .joined(separator: " ")
        return TranscriptSanitizer.clean(joined)
    }
}
