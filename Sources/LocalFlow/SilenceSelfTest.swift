import Foundation

/// `LocalFlow --silence-selftest` — the hands-free auto-stop rule, run against
/// synthetic rooms.
///
/// It exists because the live rule only ever happens in front of a microphone,
/// and because the first version of it shipped broken in a way one test in a
/// quiet room could not have caught: a robot vacuum in the background sat above
/// a fixed threshold, so the session never ended. Every case below is a *room*,
/// not a number — the audio is synthesized, the level trace is derived from
/// that same audio exactly as `AudioRecorder` derives it, and both halves of the
/// decision (when to stop, and whether what was captured is worth transcribing)
/// are answered from it.
enum SilenceSelfTest {
    /// 4096-frame buffers at a 48 kHz input — what the mic tap actually
    /// delivers, resampled here to the 16 kHz the rest of the pipeline uses.
    private static let blockSeconds = 4096.0 / 48_000.0
    private static let sampleRate = 16_000.0

    /// A stretch of speech inside a session: when it starts, how long it runs,
    /// and how loud (peak amplitude, 0…1).
    private struct Speech {
        let start: Double
        let duration: Double
        let amplitude: Float
    }

    /// Builds a recording: a bed of room noise for the whole session, with
    /// speech-shaped bursts laid over it. Speech is syllables — 200 ms on,
    /// 100 ms off — because a single sustained tone would pass a rule that a
    /// real voice breaks.
    /// A room that isn't merely loud but *lumpy*: a hum with something
    /// knocking into things every few seconds. This, not a steady bed, is what
    /// a robot vacuum actually sounds like to a microphone.
    private struct Clatter {
        let every: Double
        let duration: Double
        let amplitude: Float
    }

    private static func room(noise: Float, speech: [Speech], clatter: Clatter? = nil, seconds: Double, seed: UInt64 = 0x5EED) -> [Float] {
        var state = seed
        func random() -> Float { // xorshift64, so a failure is reproducible
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(Double(state % 20_001) / 10_000.0 - 1.0) // −1…1
        }

        let count = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count { samples[i] = random() * noise }
        if let clatter {
            var at = clatter.every
            while at < seconds {
                let from = Int(at * sampleRate)
                let to = min(count, Int((at + clatter.duration) * sampleRate))
                for i in from..<max(from, to) { samples[i] += random() * clatter.amplitude }
                at += clatter.every
            }
        }
        for burst in speech {
            let from = Int(burst.start * sampleRate)
            let to = min(count, Int((burst.start + burst.duration) * sampleRate))
            guard from < to else { continue }
            for i in from..<to {
                let t = Double(i - from) / sampleRate
                // 300 ms syllable cycle, voiced 2/3 of it.
                guard t.truncatingRemainder(dividingBy: 0.3) < 0.2 else { continue }
                let voice = sin(2 * .pi * 180 * t) * 0.7 + sin(2 * .pi * 430 * t) * 0.3
                samples[i] += Float(voice) * burst.amplitude
            }
        }
        return samples
    }

    /// The level stream `AudioRecorder.onLevel` would publish for this audio.
    private static func levels(_ samples: [Float]) -> [(level: Float, at: TimeInterval)] {
        let blockSize = Int(blockSeconds * sampleRate)
        var out: [(Float, TimeInterval)] = []
        var start = 0
        while start + blockSize <= samples.count {
            var sumOfSquares: Float = 0
            for i in start..<(start + blockSize) { sumOfSquares += samples[i] * samples[i] }
            let rms = (sumOfSquares / Float(blockSize)).squareRoot()
            out.append((min(1, rms * 12), Double(start) / sampleRate))
            start += blockSize
        }
        return out
    }

    /// Plays a recording past the detector and reports when, if ever, it would
    /// have ended the session.
    private static func firesAt(_ samples: [Float], timeout: TimeInterval) -> Double? {
        var detector = SilenceDetector(timeout: timeout, now: 0)
        for (level, at) in levels(samples) {
            detector.note(level: level, at: at)
            if detector.isSilent(at: at) { return at }
        }
        return nil
    }

    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "ok  " : "FAIL") \(name) — \(detail)")
            if !ok { failures.append(name) }
        }
        func fired(_ at: Double?) -> String { at.map { String(format: "%.0fs", $0) } ?? "never" }

        // Amplitudes chosen so the derived levels land where a real mic puts
        // them: a quiet room near 0.03, a machine running near 0.25, a voice
        // at the top of the meter.
        let quietRoom: Float = 0.0043
        let machine: Float = 0.036
        let voice: Float = 0.10

        // 1. The ordinary case: a quiet room, six seconds of speech, then you
        //    walk away.
        let ordinary = room(noise: quietRoom, speech: [.init(start: 0, duration: 6, amplitude: voice)], seconds: 50)
        let ordinaryAt = firesAt(ordinary, timeout: 30)
        // 6s of speech + 30s timeout + the ~2.5s the activity average takes to
        // decay past its threshold once the talking stops. That lag is the
        // price of not treating a single loud block as speech, and it is paid
        // on the safe side — late, never early.
        expect("quiet room: stops ~30s after the last word",
               ordinaryAt.map { abs($0 - 38.5) < 2.5 } ?? false, "fired \(fired(ordinaryAt)), expected ~38s")
        expect("quiet room: the speech is kept", SilenceTrimmer.containsSpeech(ordinary), "containsSpeech")

        // 2. THE REGRESSION. A machine running in the background is far above
        //    any fixed threshold; the first version of this rule never stopped.
        let noisy = room(noise: machine, speech: [.init(start: 0, duration: 6, amplitude: voice)], seconds: 50)
        let noisyAt = firesAt(noisy, timeout: 30)
        expect("machine running: still stops ~30s after the last word",
               noisyAt.map { abs($0 - 38.5) < 3.5 } ?? false, "fired \(fired(noisyAt)), expected ~38s")
        expect("machine running: the speech is kept", SilenceTrimmer.containsSpeech(noisy), "containsSpeech")

        // 3. …and a session that is only the machine ends AND is thrown away,
        //    rather than handed to a model that will invent sentences from it.
        let machineOnly = room(noise: machine, speech: [], seconds: 50)
        let machineOnlyAt = firesAt(machineOnly, timeout: 30)
        expect("machine alone: ends the session",
               machineOnlyAt.map { abs($0 - 30) < 2 } ?? false, "fired \(fired(machineOnlyAt)), expected ~30s")
        expect("machine alone: nothing is transcribed", !SilenceTrimmer.containsSpeech(machineOnly), "containsSpeech=false")

        // 4. The machine is switched on *after* you stop talking — the room
        //    estimate has to climb to meet it instead of waiting forever.
        let late = room(noise: quietRoom, speech: [.init(start: 0, duration: 5, amplitude: voice)], seconds: 90)
        var lateMix = late
        let machineFrom = Int(12 * sampleRate)
        let bed = room(noise: machine, speech: [], seconds: 90)
        for i in machineFrom..<lateMix.count { lateMix[i] += bed[i] }
        let lateAt = firesAt(lateMix, timeout: 30)
        expect("machine switched on mid-silence: still stops", lateAt != nil, "fired \(fired(lateAt))")

        // 5. A soft speaker must not be cut off mid-sentence — the failure this
        //    rule is biased against.
        let soft = room(noise: quietRoom, speech: [.init(start: 0, duration: 120, amplitude: 0.03)], seconds: 120)
        let softAt = firesAt(soft, timeout: 30)
        expect("soft voice is never cut off", softAt == nil, "fired \(fired(softAt)) over 120s of quiet speech")

        // 6. Nor is a long pause to think.
        let thinking = room(noise: quietRoom, speech: [
            .init(start: 0, duration: 5, amplitude: voice),
            .init(start: 30, duration: 5, amplitude: voice),
        ], seconds: 45)
        let thinkingAt = firesAt(thinking, timeout: 30)
        expect("rides out a 25s thinking pause", thinkingAt.map { $0 > 34 } ?? true, "fired \(fired(thinkingAt))")

        // 7. Tapped on by accident in a silent room.
        let empty = room(noise: 0, speech: [], seconds: 50)
        let emptyAt = firesAt(empty, timeout: 30)
        expect("silence: ends the session",
               emptyAt.map { abs($0 - 30) < 2 } ?? false, "fired \(fired(emptyAt)), expected ~30s")
        expect("silence: nothing is transcribed", !SilenceTrimmer.containsSpeech(empty), "containsSpeech=false")

        // 8. Two seconds of speech inside a minute of waiting — the case that
        //    rules out reusing the trimmer's percentile test here.
        let brief = room(noise: quietRoom, speech: [.init(start: 0, duration: 2, amplitude: voice)], seconds: 60)
        expect("2s of speech in a 60s session is still speech",
               SilenceTrimmer.containsSpeech(brief), "containsSpeech")

        // 9. THE REGRESSION THIS RULE WAS REWRITTEN FOR, from a real
        //    measurement: a hum at level ~0.09 whose top 5% of blocks reach
        //    ~0.25 — a robot vacuum knocking into furniture. Every spike used
        //    to count as speech, so the timer never ran 30s clear and the
        //    session recorded until it was stopped by hand.
        let bumpy = Clatter(every: 3, duration: 0.2, amplitude: machine * 1.6)
        let vacuum = room(noise: 0.013, speech: [.init(start: 0, duration: 6, amplitude: voice)],
                          clatter: bumpy, seconds: 80)
        let vacuumAt = firesAt(vacuum, timeout: 30)
        expect("clattering vacuum: stops instead of recording forever",
               vacuumAt.map { $0 < 50 } ?? false, "fired \(fired(vacuumAt)), expected under 50s")
        expect("clattering vacuum: the speech is kept", SilenceTrimmer.containsSpeech(vacuum), "containsSpeech")

        // …and the same room with nobody in it ends too, without inventing a
        // transcript out of the knocking.
        let vacuumOnly = room(noise: 0.013, speech: [], clatter: bumpy, seconds: 80)
        let vacuumOnlyAt = firesAt(vacuumOnly, timeout: 30)
        expect("clattering vacuum alone: ends the session",
               vacuumOnlyAt.map { $0 < 45 } ?? false, "fired \(fired(vacuumOnlyAt))")

        // 10. THE LIMIT, stated rather than hidden. A voice no louder than the
        //    machine it is competing with can't be separated from it by any of
        //    this — and Whisper would make little of it either. Printed with
        //    its numbers so the boundary is visible when it moves.
        for ratio in [Float(3.0), 2.0, 1.5, 1.0] {
            let take = room(noise: machine, speech: [.init(start: 0, duration: 6, amplitude: machine * ratio)], seconds: 50)
            let at = firesAt(take, timeout: 30)
            let kept = SilenceTrimmer.containsSpeech(take)
            let verdict = at == nil ? "never stops" : (kept ? "stops, keeps the speech" : "stops, discards as room")
            print("     voice at \(String(format: "%.1f", ratio))x the machine → \(verdict) (\(fired(at)))")
        }

        print(failures.isEmpty ? "\nall auto-stop cases passed" : "\nFAILED: \(failures.joined(separator: ", "))")
        return failures.isEmpty
    }
}
