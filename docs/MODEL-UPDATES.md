# Keeping LocalFlow's models current

Four things drift independently, and only one of them shows up in `git status`.
This doc is the standing process for staying current without chasing every
release.

The split that matters:

- **`make check-updates`** answers *did anything change?* — cheap, mechanical, monthly.
- **`make bench`** answers *is the new thing actually better for me?* — the only
  thing that should ever move the default model.

A model being newer is not a reason to switch. A bench win is.

## `make check-updates`

Checks, in one pass:

| What | Source | Why it can't be eyeballed |
|---|---|---|
| SwiftPM deps | `Package.resolved` vs upstream git tags | tags sort lexically; `1.9.4` looks newer than `1.17.0` |
| WhisperKit CoreML models | `argmaxinc/whisperkit-coreml` HF API | a new model just appears in the repo — no release, no notification |
| Alternative ASR engines | watchlist in `scripts/check-updates.py` | see "Engines worth watching" below |
| Ollama CLI | `brew info ollama` | — |
| Ollama weights | local manifest digest vs registry | **a retagged model has the same name in `ollama list`** — only the digest reveals it |

New findings are marked `+`. Once triaged, re-run with `--accept` to snapshot
the current state so the same items stop being reported:

```sh
make check-updates
python3 scripts/check-updates.py --accept
```

`scripts/model-snapshot.json` is the committed baseline of what's been seen.

## `make bench`

Runs every candidate model over `bench/samples/` and reports error rate,
latency, throughput, and peak RSS.

```sh
make bench-init                       # synthesize the starter corpus (once)
make bench                            # all default models -> reports/bench-<date>.json
python3 scripts/bench.py --models tiny,base
```

Samples are `<lang>-<name>.wav` plus a `<lang>-<name>.txt` reference of exactly
what was said. The language prefix picks the decode language and the scoring
unit: **WER** (words) for space-delimited languages, **CER** (characters) for
`zh/ja/ko/yue/th`, where word-level scoring is meaningless.

### What the numbers do and don't mean

- **Synthesized samples are a floor, not a prediction.** `make bench-init` uses
  macOS `say`, which is clean studio speech. Record *your own voice* saying the
  same lines, drop them in with the same naming, and the numbers start
  predicting your real dictation. The report labels which is which.
- **Numbers and punctuation are normalized before scoring.** A model that writes
  `4:30` where the reference says "four thirty" is right, and scoring it as
  three errors would have made the whole bench useless (it did, at first).
  Punctuation is stripped because it's the *cleanup* stage's job, not the ASR
  stage's.
- **`load` includes download + ANE compile on a model's first run.** The first
  number for a fresh model is not its steady-state load time — re-run.
- **`peak RAM` is process RSS, which understates CoreML/ANE models** — the
  weights don't live in this process. Use it to compare models, not to size a Mac.

## Current state (2026-07-19)

Measured with `make bench` on the synthesized corpus, M-series:

| model | err | load | speed | peak RSS |
|---|---|---|---|---|
| **large-v3-v20240930_626MB** (default) | **0.0%** | 4.0s | 6.0x realtime | 0.14 GB |
| small | 3.1% | 48.0s¹ | 14.8x | 0.40 GB |
| base | 12.8% | 20.0s¹ | 39.7x | 0.15 GB |
| tiny | 16.2% | 4.3s | 60.2x | 0.11 GB |

¹ first-run download + compile included.

The default is the right default: perfect on this corpus, and 6x realtime is
far below the threshold where push-to-talk feels slow. The smaller models only
make sense if first-load time on a cold app start becomes the complaint.

Also worth recording, because it cost a round of debugging:

- **large-v3-turbo already emits Simplified Chinese** when the language is
  pinned to `zh`. Only `tiny` emits Traditional — a small-model artifact.
- **Do not set `promptTokens` to bias the output script.** Conditioning the
  decoder with a Simplified-Chinese prompt made large-v3-turbo return an
  **empty transcript**. It "fixed" a bug the default model never had.

## Engines worth watching

The open Whisper CoreML lineup hasn't moved since large-v3-turbo (2024-09-30).
Argmax's newer, faster work (`parakeetkit-pro`, `qwenasrkit-pro`, `ctckit-pro`)
sits in `-pro` repos under a commercial licence, so it's not a drop-in.

The one live free alternative is **[FluidAudio](https://github.com/FluidInference/FluidAudio)**
running `parakeet-tdt-0.6b-v3-coreml`: 0.6B vs Whisper's 1.55B, ~2.5% WER on
LibriSpeech, also ANE. It covers **25 European languages only — no Chinese,
Japanese, or Korean**, which rules it out as a straight replacement here. It
would only make sense as a per-language engine switch (Parakeet when the
language is pinned to a supported one, Whisper otherwise) — worth the
complexity only if load time or latency becomes a real complaint.

It's on the `check-updates` watchlist so a language-coverage expansion doesn't
go unnoticed.

## Cadence

Monthly is enough — the upstream repos move on the order of months. Run
`make check-updates`; if it reports nothing, you're done. If it reports a new
model, add it to `AppState.models`, run `make bench`, and switch only if it wins
on the axis you care about.
