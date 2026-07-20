import Foundation

/// Phase-2 "Smart Formatting" layer: sends the raw transcript to a local
/// Ollama model for punctuation/filler cleanup. The boundary is deliberate:
/// the LLM formats, it does NOT "correct" words it thinks were misheard —
/// that's the ASR stage's job, and an LLM guessing at them invents content.
/// Why cleanup is (or isn't) available. Cleanup failing is *silent* by design —
/// dictation must never block on the LLM — so the reason is surfaced in the
/// menu bar and Settings instead of being swallowed.
enum OllamaHealth: Equatable {
    case unknown
    case ok
    case notRunning
    case modelMissing(String)

    /// Menu/Settings warning, or nil when cleanup will actually run.
    var warning: String? {
        switch self {
        case .unknown, .ok: nil
        case .notRunning: "Ollama isn’t running — cleanup is being skipped"
        case .modelMissing(let model): "Ollama is missing \(model) — cleanup is being skipped"
        }
    }

    /// The one command that fixes it, shown under the warning.
    var fixHint: String? {
        switch self {
        case .unknown, .ok: nil
        case .notRunning: "Start it with:  ollama serve"
        case .modelMissing(let model): "Install it with:  ollama pull \(model)"
        }
    }
}

enum OllamaCleaner {
    static let model = "gemma3:4b"
    private static let endpoint = URL(string: "http://127.0.0.1:11434/api/generate")!
    private static let tagsEndpoint = URL(string: "http://127.0.0.1:11434/api/tags")!

    /// Checks whether cleanup can actually run: is the server up, and is the
    /// model pulled? Cheap (a local GET), so it's safe to call on launch, when
    /// the toggle flips, and after any failed cleanup.
    static func probe() async -> OllamaHealth {
        var request = URLRequest(url: tagsEndpoint, timeoutInterval: 3)
        request.httpMethod = "GET"
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["models"] as? [[String: Any]]
        else {
            return .notRunning
        }
        // Ollama reports "gemma3:4b"; a bare "gemma3" pull registers as "gemma3:latest".
        let names = models.compactMap { $0["name"] as? String }
        let installed = names.contains(model)
            || (model.hasSuffix(":latest") && names.contains(String(model.dropLast(7))))
        return installed ? .ok : .modelMissing(model)
    }

    private static let instructions = """
    You clean up raw speech-to-text dictation. Rewrite the transcript with:
    - correct punctuation, capitalization, and grammar
    - filler words removed (um, uh, like, you know)
    - false starts and self-corrections resolved (keep only what the speaker settled on; \
    phrases like "actually" or "scratch that" signal a correction)
    Preserve the speaker's meaning, wording, and tone. Do NOT change or "correct" words \
    you think were misheard. Do NOT add anything. Do NOT translate — reply in the same \
    language as the transcript. Reply with ONLY the cleaned text.

    Transcript:
    """

    /// Returns the cleaned text, or nil if Ollama is unreachable, times out,
    /// or replies with anything unusable — the caller falls back to the raw
    /// transcript so dictation never blocks on the LLM.
    static func clean(_ text: String) async -> String? {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "prompt": instructions + text,
            "stream": false,
            "options": ["temperature": 0.1],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cleaned = (json["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !cleaned.isEmpty
        else {
            return nil
        }
        return cleaned
    }
}
