import Foundation
import os

private let log = Logger(subsystem: "ai.xdlab.LocalFlow", category: "silence")

/// Decides, from the live microphone level, when a hands-free session has
/// gone quiet and should end itself.
///
/// Push-to-talk doesn't need this — the recording is bounded by how long you
/// hold the key. Hands-free is a tap on and a tap off, and the second tap is
/// the one that's easy to forget: without it the mic keeps recording until
/// something else stops it.
///
/// **The bar for "quiet" is measured, not fixed.** A first version compared the
/// level against a constant, and a robot vacuum in the room sat above that
/// constant — so every buffer counted as sound, the timer reset forever, and
/// the session never ended (2026-09-20). Absolute level means nothing on its
/// own: it depends on the mic, the gain, how close you sit and what else is
/// switched on. What's stable is the *contrast* between the room and a voice,
/// which is the same conclusion `SilenceTrimmer` reached offline. So the room
/// is tracked continuously and the bar rides on top of it.
struct SilenceDetector {
    /// The bar never drops below this, so a dead-quiet room can't make a
    /// rounding error look like speech.
    static let absoluteFloor: Float = 0.04
    /// How far above the measured room a sample has to be to count as sound.
    /// Steady noise is remarkably steady — block-to-block RMS varies by a few
    /// percent — so telling a machine from itself needs almost no margin. The
    /// margin is spent on the other side: a voice over a running machine is
    /// only a few dB above it, and a bar set for a quiet room (2.5×, what
    /// `SilenceTrimmer` can afford offline) puts the speech itself under the
    /// bar and stops the session while you are talking.
    static let contrast: Float = 1.8
    /// The room estimate falls this fast (time constant, seconds) — quickly,
    /// so the gaps between syllables pull it back down to the real floor.
    static let floorFallTime: TimeInterval = 0.3
    /// …and rises this slowly, so a voice can't drag the room up after itself.
    /// Slow enough to ignore speech, fast enough that a vacuum switched on
    /// mid-session is absorbed within a timeout.
    static let floorRiseTime: TimeInterval = 8
    /// Window (time constant, seconds) over which "how much of the recent
    /// audio cleared the bar" is averaged.
    static let activityTime: TimeInterval = 3
    /// …and how much of it has to have cleared the bar for someone to be
    /// talking. **This is the part that matters.** Clearing the bar *at all*
    /// is not evidence of speech: a machine knocking into a chair leg spikes
    /// far above its own hum for a tenth of a second, and a first version that
    /// treated one loud block as speech reset the timer every few seconds and
    /// never ended the session (measured in a real room, 2026-09-20: the hum
    /// sat at 0.09 but the top 5% of blocks hit 0.25). Speech is the opposite
    /// shape — it *keeps* clearing the bar, syllable after syllable, for
    /// seconds. So the question asked is what fraction of the last few seconds
    /// was above the bar, not whether any of it was.
    static let activityThreshold: Float = 0.25

    let timeout: TimeInterval
    private let startedAt: TimeInterval
    private var lastNoteAt: TimeInterval
    private var lastSoundAt: TimeInterval?
    private(set) var peak: Float = 0
    /// Running estimate of the room: whatever is in the air when nobody is
    /// talking. Starts unset so the first sample seeds it instead of being
    /// judged against a guess.
    private var room: Float?
    /// Smoothed fraction of recent blocks that cleared the bar: ~0.6–0.9 while
    /// someone is talking, ~0.05 for a room that merely clatters now and then.
    private var activity: Float = 0
    /// The longest stretch that ever counted as quiet. The single most useful
    /// number when auto-stop does *not* fire: it says how close it came.
    private(set) var longestQuiet: TimeInterval = 0
    /// Coarse histogram of every level seen, for the one-line summary logged
    /// when the session ends. A percentile of what the mic actually heard is
    /// the only way to tune this rule against a real room rather than a
    /// synthetic trace.
    private var histogram = [Int](repeating: 0, count: 20)

    init(timeout: TimeInterval, now: TimeInterval) {
        self.timeout = timeout
        startedAt = now
        lastNoteAt = now
    }

    /// The level a sample has to reach, right now, to count as sound.
    var threshold: Float { max(Self.absoluteFloor, (room ?? 0) * Self.contrast) }

    mutating func note(level: Float, at now: TimeInterval) {
        peak = max(peak, level)
        histogram[min(histogram.count - 1, max(0, Int(level * Float(histogram.count))))] += 1

        // Clamped: a stalled audio thread or a laptop waking from sleep must
        // not hand the tracker a jump it treats as elapsed room time.
        let dt = min(max(now - lastNoteAt, 0), 0.5)
        lastNoteAt = now
        if let current = room {
            let tau = level < current ? Self.floorFallTime : Self.floorRiseTime
            room = current + (level - current) * Float(min(1, dt / tau))
        } else {
            room = level
        }

        let above: Float = level >= threshold ? 1 : 0
        activity += (above - activity) * Float(min(1, dt / Self.activityTime))
        if activity >= Self.activityThreshold {
            longestQuiet = max(longestQuiet, now - (lastSoundAt ?? startedAt))
            lastSoundAt = now
        }
    }

    /// True once the room has been quiet for the whole timeout. Before any
    /// sound at all it counts from the start of the session, so a hands-free
    /// tap nobody followed with speech ends too.
    func isSilent(at now: TimeInterval) -> Bool {
        now - (lastSoundAt ?? startedAt) >= timeout
    }

    /// One line for the log when a session ends, whichever way it ended. The
    /// percentiles are the useful part: they say what this room's floor and
    /// this voice's peak actually were, so a rule that misbehaves can be
    /// diagnosed from a real session instead of re-derived from a guess.
    func summary(at now: TimeInterval) -> String {
        let total = histogram.reduce(0, +)
        func percentile(_ fraction: Double) -> String {
            guard total > 0 else { return "—" }
            var seen = 0
            for (bucket, count) in histogram.enumerated() {
                seen += count
                if Double(seen) >= Double(total) * fraction {
                    return String(format: "%.2f", Double(bucket) / Double(histogram.count))
                }
            }
            return "1.00"
        }
        let quiet = now - (lastSoundAt ?? startedAt)
        return String(
            format: "levels p10=%@ p50=%@ p95=%@ peak=%.2f · room=%.3f bar=%.3f activity=%.2f · quiet %.1fs (longest %.1fs) of %.0fs · %d samples",
            percentile(0.10), percentile(0.50), percentile(0.95),
            Double(peak), Double(room ?? 0), Double(threshold), Double(activity),
            quiet, max(longestQuiet, quiet), timeout, total
        )
    }
}

/// Runs a `SilenceDetector` against the live level stream and calls back once,
/// on the main actor, when the session has gone quiet.
@MainActor
final class SilenceWatchdog {
    /// Coarse on purpose: the thing being measured is tens of seconds long, and
    /// the level stream already arrives many times a second.
    private static let tickInterval: TimeInterval = 0.5

    private var detector: SilenceDetector?
    private var timer: Timer?
    private var onSilence: (() -> Void)?

    func start(timeout: TimeInterval, onSilence: @escaping () -> Void) {
        stop()
        detector = SilenceDetector(timeout: timeout, now: Self.now)
        self.onSilence = onSilence
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Fed from `AudioRecorder.onLevel`. A no-op unless a session is watched,
    /// so push-to-talk costs nothing.
    func note(level: Float) {
        detector?.note(level: level, at: Self.now)
    }

    /// Logs what this session's room actually sounded like, then disarms.
    /// Called however the session ended, because the interesting case is the
    /// one where auto-stop did *not* fire.
    func stop() {
        if let detector {
            log.notice("\(detector.summary(at: Self.now), privacy: .public)")
        }
        timer?.invalidate()
        timer = nil
        detector = nil
        onSilence = nil
    }

    private func tick() {
        guard let detector, detector.isSilent(at: Self.now) else { return }
        let fire = onSilence
        // Torn down before the callback: it may start a new session, and that
        // one must not inherit this watchdog's timer.
        stop()
        fire?()
    }

    private static var now: TimeInterval { Date.timeIntervalSinceReferenceDate }
}
