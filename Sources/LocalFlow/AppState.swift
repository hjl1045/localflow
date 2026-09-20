import AppKit
import AVFoundation
import KeyboardShortcuts
import SwiftUI
import os

private let log = Logger(subsystem: "ai.xdlab.LocalFlow", category: "pipeline")

extension KeyboardShortcuts.Name {
    /// Hold to record, release to transcribe + inject.
    ///
    /// NOT ⌥Space, which reads like the natural choice: it's the factory default
    /// of Alfred, Raycast and LaunchBar, so a new user's first press opens their
    /// launcher instead of starting dictation — with no hint as to why. These
    /// defaults are only a starting point anyway; both are re-recordable in
    /// Settings, and an existing user's saved shortcut is unaffected.
    static let pushToTalk = Self("pushToTalk", default: .init(.m, modifiers: [.control, .command]))
    /// Tap once to start hands-free recording, tap again to stop.
    static let toggleDictation = Self("toggleDictation", default: .init(.k, modifiers: [.shift, .command]))
    /// Esc, to abandon the session in flight. Registered only *while* one is
    /// running — a bare Escape claimed globally would swallow the key for every
    /// app on the Mac, which is why it isn't re-recordable in Settings either.
    static let cancelDictation = Self("cancelDictation", default: .init(.escape))
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

        /// True while a dictation is in flight — recording, or working on what
        /// was recorded. Exactly the states Esc cancels, and exactly when the
        /// Esc hotkey is claimed.
        var isSession: Bool {
            switch self {
            case .recording, .transcribing, .cleaning: true
            default: false
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
    /// larger = more accurate. Turbo is the balanced default — see
    /// docs/MODEL-UPDATES.md for the measured error rates behind that choice.
    static let models: [(name: String, id: String)] = [
        ("Turbo — large-v3 (most accurate)", "large-v3-v20240930_626MB"),
        ("Small (faster)", "small"),
        ("Base (fast)", "base"),
        ("Tiny (fastest)", "tiny"),
    ]

    /// Auto-stop choices for hands-free: how long the room may stay quiet
    /// before the session ends itself. 0 = never, the behaviour before this.
    static let silenceTimeouts: [(name: String, seconds: Double)] = [
        ("Never", 0), ("After 15 seconds", 15), ("After 30 seconds", 30), ("After 60 seconds", 60),
    ]

    @Published var status: Status = .loadingModel {
        didSet {
            guard status.isSession != oldValue.isSession else { return }
            syncCancelHotkey()
        }
    }
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
    /// Seconds of silence that end a hands-free session on their own.
    @Published var silenceTimeout: Double {
        didSet { UserDefaults.standard.set(silenceTimeout, forKey: "silenceTimeoutSeconds") }
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
    private let watchdog = SilenceWatchdog()
    private var recordingMode: RecordingMode = .pushToTalk
    /// Bumped whenever a session starts or is abandoned, so work already in
    /// flight when Esc landed can tell its result is no longer wanted. Without
    /// it a cancelled transcription would still arrive at the cursor a second
    /// later — the one outcome the key exists to prevent.
    private var sessionID = 0
    private var transcriptionTask: Task<Void, Never>?

    /// False only in the `--diagnostics` dump, so a report can say so rather
    /// than presenting an initial-state placeholder as the real status.
    let live: Bool

    /// `live: false` builds the same settings-backed state without claiming the
    /// hotkeys, prompting for the microphone or loading a model — what the
    /// `--diagnostics` dump needs, so the report the UI sends can be assembled
    /// and inspected from a terminal instead of only by clicking.
    init(live: Bool = true) {
        self.live = live
        cleanupEnabled = UserDefaults.standard.bool(forKey: "cleanupEnabled")
        languageCode = UserDefaults.standard.string(forKey: "languageCode") ?? "auto"
        modelName = UserDefaults.standard.string(forKey: "modelName") ?? Transcriber.defaultModel
        // `object(forKey:)` rather than `double(forKey:)`: an unset key reads
        // as 0, which is the "never" choice, so a first run would silently opt
        // out of the default instead of taking it.
        silenceTimeout = UserDefaults.standard.object(forKey: "silenceTimeoutSeconds") as? Double ?? 30
        overlayPosition = OverlayPosition(rawValue: UserDefaults.standard.string(forKey: "overlayPosition") ?? "") ?? .bottomCenter
        overlay.position = overlayPosition
        recorder.onLevel = { [weak self] level in
            self?.overlay.setLevel(level)
            self?.watchdog.note(level: level)
        }
        guard live else { return }
        registerHotkey()
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        // Surface both permission prompts up front, then load the model.
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        TextInjector.promptForAccessibilityIfNeeded()
        if micGranted {
            do {
                try await transcriber.load(modelName)
                status = .idle
            } catch {
                status = .error("Model load failed: \(error.localizedDescription)")
            }
            if cleanupEnabled { refreshOllamaHealth() }
        } else {
            status = .error("Microphone access denied. Grant it in System Settings → Privacy & Security → Microphone.")
        }
        // Last, so it never competes with the permission dialogs for focus.
        offerPreviousCrashReport()
    }

    /// If the previous run left a crash report, offer it — exactly once.
    ///
    /// Marked seen at *offer* time, not at send time: an unreported crash that
    /// re-prompts at every login would train the user to dismiss the prompt,
    /// which costs the next real one.
    private func offerPreviousCrashReport() {
        guard let crash = CrashReports.newestUnseen() else { return }
        CrashReports.markSeen(crash)
        log.notice("offering crash report: \(crash.fileName, privacy: .public)")
        AppDelegate.presentCrashPrompt(appState: self, crash: crash)
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
        KeyboardShortcuts.onKeyDown(for: .cancelDictation) { [weak self] in
            self?.cancelSession()
        }
        // `onKeyDown` registers it; nothing is dictating yet, so hand Esc back
        // to the rest of the Mac until something is.
        KeyboardShortcuts.disable(.cancelDictation)
    }

    /// Claim Esc for the length of a session and give it straight back, so a
    /// bare Escape isn't swallowed system-wide the rest of the time.
    ///
    /// Deferred to the next main-loop turn, and written to converge on whatever
    /// `status` says *then* rather than to apply a remembered transition. The
    /// reason is the cancel path: it runs inside the Carbon handler for this
    /// very hot key, and `UnregisterEventHotKey` from inside its own callback
    /// is not somewhere to find out we were wrong. Re-reading the state also
    /// makes an enable that overtakes a pending disable harmless.
    private func syncCancelHotkey() {
        guard live else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if status.isSession {
                KeyboardShortcuts.enable(.cancelDictation)
            } else {
                KeyboardShortcuts.disable(.cancelDictation)
            }
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
        } else if status == .loadingModel {
            overlay.flash(.loadingModel)
            log.notice("toggle during model load — told the user instead of ignoring it")
        } else {
            log.notice("toggle ignored: status=\(String(describing: self.status))")
        }
    }

    private func startRecording(mode: RecordingMode) {
        log.notice("startRecording mode=\(String(describing: mode)) status=\(String(describing: self.status))")
        // A press during a model load has to be answered, not dropped: the
        // menu bar turns to an hourglass, but the user is in another app and
        // won't see it, so the hotkey looks broken for the 5-7s a switch takes.
        if status == .loadingModel {
            overlay.flash(.loadingModel)
            return
        }
        guard status == .idle else { return } // ignore key-repeat and busy states
        do {
            try recorder.start()
            sessionID &+= 1
            recordingMode = mode
            status = .recording
            overlay.show(.listening)
            // Push-to-talk is already bounded by the key being held; only the
            // hands-free session can be left running by mistake.
            if mode == .toggle, silenceTimeout > 0 {
                watchdog.start(timeout: silenceTimeout) { [weak self] in
                    self?.silenceElapsed()
                }
            }
        } catch {
            log.error("mic start failed: \(error.localizedDescription)")
            status = .error("Mic start failed: \(error.localizedDescription)")
        }
    }

    /// Esc: abandon this session. While recording that discards the audio;
    /// while transcribing or cleaning it discards the text, which is the case
    /// that actually matters — a cancelled dictation must never still land at
    /// the cursor a second later.
    ///
    /// Not private: it's also how the menu bar could offer the same thing, and
    /// it's the single place a session is torn down.
    func cancelSession(reason: String = "esc", notice: RecordingOverlay.Mode = .cancelled) {
        guard status.isSession else { return }
        log.notice("cancelled (\(reason, privacy: .public)) at status=\(String(describing: self.status))")
        sessionID &+= 1
        watchdog.stop()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if status == .recording { _ = recorder.stop() }
        status = .idle
        // Say so rather than just vanishing: Esc making the pill disappear
        // silently is indistinguishable from the app dying mid-dictation.
        overlay.flash(notice, seconds: 1.2)
    }

    /// The hands-free session went quiet for the whole timeout.
    ///
    /// Whether to transcribe what's there is asked of the *audio*, not of the
    /// level meter that just fired. The meter only knows the room was loud
    /// enough to keep resetting a timer; a machine running in the background
    /// clears that bar all session without a word being said, and handing
    /// Whisper a minute of it produces invented sentences, not silence.
    private func silenceElapsed() {
        guard status == .recording, recordingMode == .toggle else { return }
        let samples = recorder.stop()
        let seconds = Double(samples.count) / AudioRecorder.targetSampleRate
        guard SilenceTrimmer.containsSpeech(samples) else {
            log.notice("auto-stop: \(seconds, format: .fixed(precision: 1))s of room with nothing said — discarded")
            cancelSession(reason: "silence, nothing said", notice: .noSpeech)
            return
        }
        log.notice("auto-stop after \(self.silenceTimeout, format: .fixed(precision: 0))s of silence")
        transcribe(samples)
    }

    private func stopAndTranscribe() {
        guard status == .recording else {
            log.notice("keyUp ignored: status=\(String(describing: self.status))")
            return
        }
        watchdog.stop()
        transcribe(recorder.stop())
    }

    /// The pipeline every stop funnels into, whoever asked for it.
    private func transcribe(_ samples: [Float]) {
        log.notice("captured \(samples.count) samples (\(Double(samples.count) / 16_000, format: .fixed(precision: 1))s)")

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
        // Every resumption point below re-checks the session: `Task.cancel()`
        // can't interrupt WhisperKit mid-inference, so the guard — not the
        // cancellation — is what keeps a cancelled transcript off the cursor.
        let session = sessionID
        transcriptionTask = Task {
            defer { if sessionID == session { overlay.hide() } }
            do {
                var text = try await transcriber.transcribe(samples, language: language)
                guard sessionID == session else {
                    log.notice("transcript dropped: session was cancelled")
                    return
                }
                log.notice("transcript: \(text.count) chars")
                guard !text.isEmpty else {
                    status = .idle
                    return
                }
                if cleanupEnabled, text.count > 50 {
                    status = .cleaning
                    let cleaned = await OllamaCleaner.clean(text)
                    guard sessionID == session else {
                        log.notice("cleanup result dropped: session was cancelled")
                        return
                    }
                    if let cleaned {
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
                    if sessionID == session, case .error = status { status = .idle }
                }
            } catch {
                guard sessionID == session else {
                    log.notice("transcription error dropped: session was cancelled")
                    return
                }
                log.error("transcription failed: \(error.localizedDescription)")
                status = .error("Transcription failed: \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(3))
                if sessionID == session, case .error = status { status = .idle }
            }
        }
    }
}
