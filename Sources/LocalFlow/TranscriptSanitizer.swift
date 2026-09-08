import Foundation

/// Strips Whisper's non-speech output from a transcript before it reaches the
/// cursor.
///
/// Whisper narrates what it hears when it isn't hearing words: the tail of a
/// push-to-talk recording is almost always a beat of silence between the last
/// word and the key release, and the model labels that `[BLANK_AUDIO]`. Music,
/// noise and laughter get the same treatment, in the language of the audio.
/// These are model annotations, never words the user said, so injecting them is
/// always wrong — and in a dictation tool the user has to delete them by hand
/// every time.
///
/// The rule is deliberately narrow: only bracketed spans that *look* like an
/// annotation are dropped. A short square-bracketed all-caps token is Whisper's
/// own format (`[BLANK_AUDIO]`, `[SOUND]`); anything else has to name a
/// non-speech event to qualify, so a genuine aside survives.
enum TranscriptSanitizer {

    /// Non-speech events, lowercased, matched as substrings of an annotation's
    /// contents. Covers the languages the default model is used in here.
    private static let nonSpeechTerms: [String] = [
        // English
        "blank_audio", "blank audio", "no audio", "no speech", "silence", "silent",
        "music", "song", "singing", "humming", "noise", "static", "beep",
        "inaudible", "unintelligible", "indistinct", "crosstalk",
        "laughter", "laughs", "laughing", "chuckles", "giggles",
        "applause", "clapping", "cheering", "sighs", "coughs", "coughing",
        "sniffles", "clears throat", "breathing", "footsteps", "typing",
        "background", "foreign language", "speaking in",
        // Chinese / Japanese / Korean
        "音乐", "音楽", "音效", "掌声", "拍手", "笑声", "咳嗽", "无声", "静音",
        "沉默", "无语音", "침묵", "박수", "음악",
        // Romance / Germanic
        "música", "musique", "musik", "risas", "rires", "aplausos",
        "applaudissements", "applaus", "gelächter", "silencio", "stille",
    ]

    /// A bracketed span: `[...]`, `(...)`, or their full-width equivalents.
    /// Non-greedy and newline-free so an unclosed bracket can't swallow the
    /// rest of the transcript.
    private static let annotation = regex("[\\[\\(（【]([^\\[\\]\\(\\)（）【】\n]*)[\\]\\)）】]")
    /// Whisper's own control tokens, if any survive decoding (`<|nospeech|>`,
    /// `<|0.00|>`).
    private static let specialToken = regex("<\\|[^|>\n]*\\|>")
    /// The other annotation shape the model uses: `*music*`, `*laughs*`.
    /// Observed from the real pipeline — a synthesized melody transcribes to
    /// exactly `*music*`, so this is not hypothetical.
    private static let starred = regex("\\*([^*\n]*)\\*")
    /// A `♪ lyrics ♪` run, or a bare note left behind by one.
    private static let musicRun = regex("[♪♫]([^♪♫\n]*)[♪♫]|[♪♫]")

    /// The longest an annotation can be and still be treated as one. Past this
    /// it is more likely to be real speech that happens to mention music.
    private static let maxAnnotationLength = 40

    static func clean(_ raw: String) -> String {
        var text = replaceAll(specialToken, in: raw) { _ in " " }
        text = replaceAll(musicRun, in: text) { _ in " " }
        text = replaceAll(annotation, in: text) { match in
            isNonSpeech(inner(of: match, in: text), squareBracketed: text.first(of: match) == "[")
                ? " "
                : nil // keep it verbatim
        }
        let starredText = text
        text = replaceAll(starred, in: starredText) { match in
            isNonSpeech(inner(of: match, in: starredText), squareBracketed: false) ? " " : nil
        }
        return tidy(text)
    }

    private static func isNonSpeech(_ contents: String, squareBracketed: Bool) -> Bool {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true } // "[]" — an annotation with its text eaten
        guard trimmed.count <= maxAnnotationLength else { return false }
        // Whisper's own token shape: [BLANK_AUDIO], [SOUND], [ NO SPEECH ].
        if squareBracketed,
           trimmed.range(of: "^[A-Z0-9 _.\\-]+$", options: .regularExpression) != nil {
            return true
        }
        let lower = trimmed.lowercased()
        return nonSpeechTerms.contains { lower.contains($0) }
    }

    /// Closes the gaps the removals left: doubled spaces, a space stranded
    /// before punctuation, blank runs.
    private static func tidy(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " +([,.;:!?…、。，；：！？])", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only punctuation survived: the whole utterance was non-speech, so
        // there is nothing to type. Callers already treat "" as "say nothing".
        if s.range(of: "[\\p{L}\\p{N}]", options: .regularExpression) == nil { return "" }
        return s
    }

    // MARK: - Regex plumbing

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Every pattern here is a literal in this file; a typo is a programmer
        // error, not something to recover from at runtime.
        try! NSRegularExpression(pattern: pattern)
    }

    /// Rewrites matches back-to-front so earlier ranges stay valid.
    /// `transform` returning nil leaves that match untouched.
    private static func replaceAll(
        _ regex: NSRegularExpression,
        in text: String,
        with transform: (NSTextCheckingResult) -> String?
    ) -> String {
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        for match in matches.reversed() {
            guard let replacement = transform(match),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// Capture group 1 — the bracket's contents.
    private static func inner(of match: NSTextCheckingResult, in text: String) -> String {
        guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return "" }
        return String(text[range])
    }
}

private extension String {
    /// The first character of a match's range — which bracket opened it.
    func first(of match: NSTextCheckingResult) -> Character? {
        guard let range = Range(match.range, in: self) else { return nil }
        return self[range].first
    }
}
