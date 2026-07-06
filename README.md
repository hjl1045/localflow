# LocalFlow

A fully-local Wispr Flow–style dictation app for Apple Silicon Macs. Hold a key, speak, release — your words are transcribed on-device and pasted at the cursor in whatever app is focused. No cloud, no accounts; audio never leaves your Mac.

- **ASR:** [WhisperKit](https://github.com/argmaxinc/WhisperKit) running Whisper **large-v3-turbo** (compressed, ~626 MB) on the Apple Neural Engine. Multilingual (~100 languages), auto-detect or pinned via Settings.
- **AI cleanup (optional):** a local [Ollama](https://ollama.com) model (`gemma3:4b`) fixes punctuation, removes filler words and false starts — mirroring Wispr Flow's "Smart Formatting"/"Backtrack", but on-device.
- **UX:** global push-to-talk hotkey (default **⌥ Option+Space**, configurable), floating waveform pill (warm-yellow reactive wave while listening, cool shimmer-sweep while transcribing; position configurable — any screen edge/corner, vertical on the sides), menu-bar status icon.

See [PLAN.md](PLAN.md) for the research this design is based on.

## Requirements

- Apple Silicon Mac (M1 or later), macOS 14+
- Xcode (or Command Line Tools with Swift 5.10+) — build only
- [Ollama](https://ollama.com) + `ollama pull gemma3:4b` — only for the optional AI-cleanup toggle

## Build & run

```sh
make run        # builds, assembles dist/LocalFlow.app, launches from dist/ (dev loop)
make install    # builds + installs to /Applications — launchable from Spotlight/Launchpad/Finder
```

`make install` is the "use it like a normal app" path: it copies `LocalFlow.app` into `/Applications` (quitting any running copy first) so Spotlight, Launchpad, and Finder can find and launch it. It has a proper app icon, and Settings has a **Launch at login** toggle so the hotkey is always live without relaunching.

First launch downloads the Whisper model (~626 MB) and compiles it for the Neural Engine — the first transcription takes ~1 min extra, one time only. After that: ~2.7 s for 10 s of speech on an M4, +~1.3 s if AI cleanup is on.

> LocalFlow is a menu-bar (accessory) app, so it has no permanent Dock icon. The Dock icon appears only briefly while the Settings window is open — that's what lets the shortcut recorder capture your keys (an accessory window otherwise can't become focused). The app icon (`Support/AppIcon.icns`) is regenerated from an SF Symbol via `Support/make-icon.sh` when the design changes.

### Permissions

Grant when prompted (System Settings → Privacy & Security):

| Permission | Why |
|---|---|
| Microphone | record while you hold the key |
| Accessibility | synthesize ⌘V to paste into the focused app |

> Dev note: the app is ad-hoc signed, so after a rebuild macOS may require re-toggling the Accessibility grant.

## Usage

1. Click into any text field, anywhere.
2. Hold **⌥ Option+Space**, speak, release.
3. The waveform pill shows it's listening; text lands at your cursor.

Menu bar icon → **Settings…** to change the push-to-talk / hands-free shortcuts, pick a language (default: auto-detect) or model, move the **listening bar** to any edge/corner, toggle AI cleanup, or enable **Launch at login**.

Headless pipeline test (no mic/UI):

```sh
./dist/LocalFlow.app/Contents/MacOS/LocalFlow --transcribe test.wav [--language es] [--clean]
```

## Moving it to another Mac

Both machines must be **Apple Silicon** (WhisperKit runs on the Neural Engine).

**A — build from source (recommended).** A locally built app isn't quarantined, so there's no Gatekeeper "unidentified developer" prompt and no signing to manage — it signs with whatever identity that Mac has (or ad-hoc).
```sh
xcode-select --install                            # once, if you don't have build tools
git clone https://github.com/hjl1045/localflow    # private repo — that Mac needs GitHub access (e.g. `gh auth login`)
cd localflow && make install                      # builds, installs to /Applications, launches it
```
Then grant **Microphone + Accessibility** when prompted. The Whisper model auto-downloads on first run (~626 MB, needs internet once). For optional AI cleanup: `brew install ollama && ollama pull gemma3:4b`.

**B — copy the built app.** Copy `dist/LocalFlow.app` (AirDrop, scp, USB). It's arm64-only and signed with a personal/dev identity (not notarized), so macOS quarantines a copied build; clear it with:
```sh
xattr -dr com.apple.quarantine LocalFlow.app
```
then launch and grant permissions. The model still auto-downloads on first run (~626 MB per machine).

## Architecture

```
⌥Space down ──► AVAudioEngine (16 kHz mono) ──► live level → waveform overlay
⌥Space up   ──► WhisperKit large-v3-turbo (ANE) ──► raw transcript
                    └─► [optional] Ollama gemma3:4b cleanup ──► polished text
                              └─► clipboard save → paste ⌘V → clipboard restore
```

| File | Role |
|---|---|
| `AppState.swift` | state machine: hotkey → record → transcribe → clean → inject |
| `AudioRecorder.swift` | mic capture, 16 kHz mono conversion, live RMS level |
| `Transcriber.swift` | WhisperKit wrapper, language/decoding options |
| `OllamaCleaner.swift` | local LLM formatting pass (never blocks dictation) |
| `TextInjector.swift` | clipboard-preserving paste-at-cursor |
| `RecordingOverlay.swift` | floating waveform pill (non-activating panel); configurable position, vertical on side edges |
| `LoginItem.swift` | launch-at-login toggle via `SMAppService` |
| `LocalFlowApp.swift` | menu bar UI, AppKit-hosted Settings window (key/focusable in an accessory app), headless test CLI |
