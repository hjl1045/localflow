import Foundation
import WhisperKit

/// Wraps WhisperKit. Loads the model once (auto-downloading it on first run)
/// and serializes transcription requests.
actor Transcriber {
    /// Compressed Whisper Large-v3-Turbo (~0.6 GB) — the balanced
    /// latency/accuracy pick from PLAN.md. WhisperKit fuzzy-matches this
    /// against the argmaxinc/whisperkit-coreml model repo.
    static let modelName = "large-v3-v20240930_626MB"

    private var whisperKit: WhisperKit?

    func load() async throws {
        guard whisperKit == nil else { return }
        let config = WhisperKitConfig(model: Self.modelName)
        whisperKit = try await WhisperKit(config)
    }

    /// Headless test path: transcribe an audio file directly.
    /// `language` is an ISO 639-1 code ("en", "es", …) or nil to auto-detect.
    func transcribe(path: String, language: String? = nil) async throws -> String {
        guard let whisperKit else {
            throw NSError(domain: "LocalFlow", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Model not loaded yet."
            ])
        }
        let results = try await whisperKit.transcribe(
            audioPath: path,
            decodeOptions: Self.decodingOptions(language: language)
        )
        return Self.joinedText(results)
    }

    func transcribe(_ samples: [Float], language: String? = nil) async throws -> String {
        guard let whisperKit else {
            throw NSError(domain: "LocalFlow", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Model not loaded yet."
            ])
        }
        let results = try await whisperKit.transcribe(
            audioArray: samples,
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

    private static func joinedText(_ results: [TranscriptionResult]) -> String {
        results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
