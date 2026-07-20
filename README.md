# LocalFlow

**English** · [中文](README.zh-CN.md)

Hold a key, speak, release — your words appear at the cursor, in whatever app you're using. Everything runs on your Mac: no cloud, no account, no API key. **Audio never leaves your machine.**

```
⌥Space (hold) ──► speak ──► release ──► text lands where your cursor is
```

## Why

Dictation is the fastest way to get words into a computer, but every good dictation tool ships your voice to someone's server. LocalFlow runs the whole pipeline on the Apple Neural Engine, so you can dictate a private message, a medical note, or an unreleased product spec without deciding whether you trust a vendor.

It's fast enough that this isn't a compromise: **a typical sentence transcribes in about one second.**

## What it does

- **Push-to-talk** — hold a hotkey (default <kbd>⌥</kbd><kbd>Space</kbd>), speak, release. Text is pasted at the cursor.
- **Hands-free mode** — tap a second hotkey to start, tap again to stop, for longer dictation.
- **~100 languages** — auto-detected, or pin one in Settings. Handles mixed-language speech.
- **Optional AI cleanup** — a local LLM fixes punctuation, removes filler words ("um", "uh"), and resolves false starts. Also fully offline.
- **Works everywhere** — any text field in any app: browser, editor, chat, terminal, Slack, notes.
- **Menu-bar app** — no Dock icon, no window in your way. A floating waveform pill shows it's listening.
- **Recent transcripts** — the last 5 dictations are recoverable from the menu if a paste missed its target.

## Typical uses

| | |
|---|---|
| **Messages and email** | Speak a reply instead of typing it — the cleanup pass makes it punctuated prose, not a transcript. |
| **Commit messages and code comments** | Dictating a *why* is faster than typing it, and technical vocabulary holds up well. |
| **Notes and journaling** | Long-form thinking out loud, straight into whatever note app you already use. |
| **Multilingual writing** | Speak in one language, or switch mid-sentence; the model follows. |
| **Anywhere private** | Anything you wouldn't want to send to a third-party server. |

## Requirements

- **Apple Silicon Mac** (M1 or later) — the speech model runs on the Neural Engine
- **macOS 14+**
- **Xcode or Command Line Tools** (Swift 5.10+) — to build
- *Optional:* [Ollama](https://ollama.com) + `ollama pull gemma3:4b` for the AI-cleanup toggle

## Install

Build from source:

```sh
git clone https://github.com/hjl1045/localflow.git
cd localflow
make install
```

That builds the app, installs it to `/Applications`, and launches it. Look for the microphone icon in your menu bar.

On first run, LocalFlow downloads the speech model (~626 MB) and compiles it for the Neural Engine. This takes about a minute, once.

### Permissions

macOS will prompt for two, both required:

| Permission | Why |
|---|---|
| **Microphone** | to record while you hold the key |
| **Accessibility** | to paste the text into the app you're using |

## Use it

1. Click into any text field.
2. Hold <kbd>⌥</kbd><kbd>Space</kbd>, speak, release.
3. Your words appear at the cursor.

Menu-bar icon → **Settings…** to change hotkeys, pick a language or model, move the waveform pill, enable AI cleanup, or launch at login.

### AI cleanup (optional)

Turn on *Clean up transcript with Ollama* in Settings, and a local LLM rewrites the raw transcript — punctuation, capitalization, filler removal, false starts resolved — before it's pasted. Needs Ollama running:

```sh
brew install ollama && brew services start ollama
ollama pull gemma3:4b
```

If Ollama isn't reachable, dictation still works; you get the raw transcript, and the menu bar tells you why cleanup was skipped.

## Performance

Measured on an M-series Mac with the default model (Whisper large-v3-turbo, 626 MB compressed):

| Utterance | Transcribe time |
|---|---|
| 3.5 s | 0.83 s |
| 5.9 s | 1.06 s |
| 13.1 s | 1.33 s |

Model load at app start: ~4 s (once per launch). AI cleanup adds a few seconds when enabled.

Smaller, faster models (small / base / tiny) are selectable in Settings — they trade accuracy for speed. See [docs/MODEL-UPDATES.md](docs/MODEL-UPDATES.md) for measured error rates and how to benchmark models on your own voice.

## How it works

```
⌥Space down ──► AVAudioEngine (16 kHz mono) ──► live level → waveform overlay
⌥Space up   ──► WhisperKit large-v3-turbo (Neural Engine) ──► raw transcript
                    └─► [optional] Ollama cleanup ──► polished text
                              └─► clipboard save → paste ⌘V → clipboard restore
```

| File | Role |
|---|---|
| `AppState.swift` | state machine: hotkey → record → transcribe → clean → inject |
| `AudioRecorder.swift` | mic capture, 16 kHz mono conversion, live level |
| `Transcriber.swift` | WhisperKit wrapper, language and decoding options |
| `OllamaCleaner.swift` | local LLM formatting pass (never blocks dictation) |
| `TextInjector.swift` | clipboard-preserving paste-at-cursor |
| `RecordingOverlay.swift` | floating waveform pill |
| `LocalFlowApp.swift` | menu-bar UI, Settings window, headless test CLI |

Headless pipeline test, no mic or UI:

```sh
./dist/LocalFlow.app/Contents/MacOS/LocalFlow --transcribe audio.wav [--language es] [--clean]
```

## Docs

| Doc | What it covers |
|---|---|
| [docs/MODEL-UPDATES.md](docs/MODEL-UPDATES.md) | keeping models current, benchmarking on your own audio, measured results |
| [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) | installing on another Mac, Homebrew cask, notarization |

## Built on

[WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper on the Neural Engine) · [Whisper](https://github.com/openai/whisper) · [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) · [Ollama](https://ollama.com)

## License

[MIT](LICENSE)
