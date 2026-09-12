# LocalFlow

**English** · [中文](README.zh-CN.md)

Hold a key, speak, release — your words appear at the cursor, in whatever app you're using. Everything runs on your Mac: no cloud, no account, no API key. **Audio never leaves your machine.**

```
⌃⌘M (hold) ──► speak ──► release ──► text lands where your cursor is
```

## Why

Dictation is the fastest way to get words into a computer, but every good dictation tool ships your voice to someone's server. LocalFlow runs the whole pipeline on the Apple Neural Engine, so you can dictate a private message, a medical note, or an unreleased product spec without deciding whether you trust a vendor.

It's fast enough to use all day — transcription starts the moment you release the key, with no upload and no round-trip.

## What it does

- **Push-to-talk** — hold a hotkey, speak, release. Text is pasted at the cursor. Both hotkeys are recorded in Settings; pick combinations nothing else on your Mac has claimed.
- **Hands-free mode** — tap a second hotkey to start, tap again to stop, for longer dictation.
- **Multilingual** — the language is auto-detected by default, or pin one of 12 in Settings (en, zh, es, fr, de, ja, ko, pt, ru, it, hi, ar). Mixed Chinese/English speech works well. The underlying Whisper model covers many more languages, but accuracy varies a lot between them and only English and Chinese are measured here — see [docs/MODEL-UPDATES.md](docs/MODEL-UPDATES.md).
- **Optional AI cleanup** — a local LLM fixes punctuation, removes filler words ("um", "uh"), and resolves false starts. Also fully offline.
- **Nothing from the silence** — you stop talking a beat before you let go of the key, and Whisper narrates that gap: sometimes as an annotation (`[BLANK_AUDIO]`, `*music*`, `[laughter]`), sometimes as a word it invents outright (`Thank you.`). The trailing silence is trimmed off the audio before the model sees it, and any annotation that still gets through is stripped before the text reaches your cursor.
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

On a Mac where you'd rather not write to `/Applications` — a work machine with endpoint security, or one where you don't have admin rights — install into your home folder instead:

```sh
make install-user
```

Same app, same signature, same permissions. It lives in `~/Applications` and nothing outside your home folder is touched. LocalFlow has no Dock icon either way (it's a menu-bar app), so this is already a background service — only the location changes. `make uninstall-user` removes it.

Install one or the other on a given machine, **not both**: two copies of the same bundle id leave macOS unsure which one your hotkey and login item refer to. If a managed Mac still blocks it, [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) covers what a location change can and can't fix.

On first run, LocalFlow downloads the speech model (~626 MB) and compiles it for the Neural Engine. This takes about a minute, once.

### Permissions

macOS will prompt for two, both required:

| Permission | Why |
|---|---|
| **Microphone** | to record while you hold the key |
| **Accessibility** | to paste the text into the app you're using |

## Use it

1. Click into any text field.
2. Hold <kbd>⌃</kbd><kbd>⌘</kbd><kbd>M</kbd> (the default — change it in Settings), speak, release.
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

Measured on an M-series Mac with the default model (Whisper large-v3-turbo, 626 MB compressed), on the **synthesized** bench corpus — clean, evenly-paced speech. Real dictation is messier and slower, so treat these as a floor, not a promise:

| Utterance | Transcribe time |
|---|---|
| 3.5 s | 0.83 s |
| 5.9 s | 1.06 s |
| 13.1 s | 1.33 s |

Model load at app start: ~4 s (once per launch). AI cleanup adds a few seconds when enabled.

Smaller, faster models (small / base / tiny) are selectable in Settings — they trade accuracy for speed. See [docs/MODEL-UPDATES.md](docs/MODEL-UPDATES.md) for measured error rates and how to benchmark models on your own voice.

## How it works

```
hotkey down ──► AVAudioEngine (16 kHz mono) ──► live level → waveform overlay
hotkey up   ──► WhisperKit large-v3-turbo (Neural Engine) ──► raw transcript
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
./dist.noindex/LocalFlow.app/Contents/MacOS/LocalFlow --transcribe audio.wav [--language es] [--clean]
```

## Docs

| Doc | What it covers |
|---|---|
| [docs/MODEL-UPDATES.md](docs/MODEL-UPDATES.md) | keeping models current, benchmarking on your own audio, measured results |
| [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) | installing on another Mac, Homebrew cask, notarization |
| [docs/FEEDBACK.md](docs/FEEDBACK.md) | reporting a bug or crash, where reports land, symbolicating a crash report |

## Found a bug, or got a question?

The quickest route is from inside the app: **menu bar icon → "Report an issue…"**. It
collects the version, model and settings that a bug report needs, shows you the entire
payload before anything is sent, and opens a draft in your own mail app — nothing is
transmitted by the app itself. Transcript text is only included if you tick the box.

Otherwise: [open an issue](https://github.com/hjl1045/localflow/issues), or mail
**hello@theautonomes.ai**.

## Built on

[WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper on the Neural Engine) · [Whisper](https://github.com/openai/whisper) · [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) · [Ollama](https://ollama.com)

## License

[MIT](LICENSE)
