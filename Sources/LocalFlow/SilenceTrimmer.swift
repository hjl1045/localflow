import Foundation

/// Trims the silence off the end of a recording before Whisper ever sees it.
///
/// Push-to-talk always captures more than speech: you stop talking, then a beat
/// later you let go of the key. Whisper doesn't ignore that gap, it narrates
/// it — sometimes as an annotation, which `TranscriptSanitizer` can strip,
/// but sometimes as a plausible word it invents outright (`Thank you.`, a
/// trailing `I'm`). Nothing downstream can safely delete a word that looks
/// real, so the only fix is to stop handing the model the silence.
///
/// Deliberately reluctant. Clipping a quiet final word is a worse failure than
/// leaving silence in, so it keeps padding past the last speech it finds,
/// ignores bursts too short to be a syllable, and gives up entirely on any
/// recording where it can't tell speech from the room.
enum SilenceTrimmer {

    /// 20 ms at 16 kHz — long enough for a stable RMS, short enough to place
    /// the end of speech precisely.
    private static let frameSize = 320
    /// Sound has to sustain 60 ms to count as speech. The key release is
    /// itself a click of a frame or two, and it lands at the very end of the
    /// recording: without this it would anchor every trim at the last sample
    /// and nothing would ever get trimmed.
    private static let minSpeechFrames = 3
    /// Kept past the last speech frame, so a trailing consonant or a fading
    /// word keeps its natural decay instead of being cut off mid-air.
    private static let padding = 4_800 // 300 ms
    /// Below this there's nothing worth reclaiming — leave the audio alone
    /// rather than risk the edit for a rounding error's worth of silence.
    private static let minWorthTrimming = 4_800 // 300 ms

    static func trimTrailingSilence(_ samples: [Float]) -> [Float] {
        let energies = frameEnergies(samples)
        guard energies.count > minSpeechFrames,
              let threshold = speechThreshold(energies),
              let lastSpeech = lastSustainedFrame(energies, above: threshold)
        else { return samples }

        let keep = min(samples.count, (lastSpeech + 1) * frameSize + padding)
        guard samples.count - keep >= minWorthTrimming else { return samples }
        return Array(samples[..<keep])
    }

    /// RMS per fixed-size frame. A trailing partial frame is dropped — it's at
    /// most 20 ms, and it would have an unstably small sample count.
    private static func frameEnergies(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count - samples.count % frameSize, by: frameSize).map { start in
            var sumOfSquares: Float = 0
            for i in start..<(start + frameSize) {
                sumOfSquares += samples[i] * samples[i]
            }
            return (sumOfSquares / Float(frameSize)).squareRoot()
        }
    }

    /// Derived from this recording rather than fixed, because the absolute
    /// level depends on the mic, the gain and how close the speaker sits —
    /// what's reliable is the *contrast* between the room and the voice.
    /// Returns nil when there isn't enough of it to be sure.
    private static func speechThreshold(_ energies: [Float]) -> Float? {
        let sorted = energies.sorted()
        let room = sorted[sorted.count / 10]           // 10th percentile: the quiet
        let voice = sorted[sorted.count * 95 / 100]    // 95th: the loud
        // No usable contrast — the take is all silence, or all noise. Either
        // way, picking a point where speech "ended" would be a coin flip.
        guard voice > 0, voice > room * 2 else { return nil }
        // Sits low on purpose: a threshold that misses the tail of a fading
        // word cuts it off, while one that's too generous only leaves silence.
        return max(room * 2.5, voice * 0.04)
    }

    /// The last frame belonging to a run of at least `minSpeechFrames` above
    /// the threshold.
    private static func lastSustainedFrame(_ energies: [Float], above threshold: Float) -> Int? {
        var lastEnd: Int?
        var run = 0
        for (index, energy) in energies.enumerated() {
            if energy >= threshold {
                run += 1
                if run >= minSpeechFrames { lastEnd = index }
            } else {
                run = 0
            }
        }
        return lastEnd
    }
}
