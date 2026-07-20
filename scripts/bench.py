#!/usr/bin/env python3
"""Benchmark WhisperKit models on LocalFlow's own pipeline.

Answers the only question that matters when a new model shows up: is it
actually better *for my audio, in my languages*, at what latency and RAM cost?

Each sample is a WAV in bench/samples/ with a sibling .txt holding the exact
words spoken. The filename's leading language tag picks the decode language and
the scoring unit:

    bench/samples/en-quickfox.wav + en-quickfox.txt   -> WER (word level)
    bench/samples/zh-tianqi.wav   + zh-tianqi.txt     -> CER (character level)

`--generate` writes a starter set using macOS `say`. Synthesized speech is
CLEAN speech: treat those numbers as a floor, not a prediction. Real recordings
of your own voice (same naming) dropped into the same folder are what make this
worth trusting -- the script prefers them and labels which is which.

Usage:
    make bench                       # all default models, all samples
    python3 scripts/bench.py --generate
    python3 scripts/bench.py --models tiny,base
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import unicodedata
import wave
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BINARY = REPO / "dist/LocalFlow.app/Contents/MacOS/LocalFlow"
SAMPLES = REPO / "bench/samples"

# Mirrors AppState.models -- the choices actually offered in Settings.
DEFAULT_MODELS = ["large-v3-v20240930_626MB", "small", "base", "tiny"]

# Character-scored languages: no word boundaries, so WER is meaningless there.
CHAR_SCORED = {"zh", "ja", "ko", "yue", "th"}

# Starter corpus for --generate: (name, language, voice, text).
# Deliberately includes the things dictation actually trips on -- numbers,
# proper nouns, code-ish tokens, a long run-on sentence.
SYNTH_SAMPLES = [
    ("en-plain", "en", "Samantha",
     "The quick brown fox jumps over the lazy dog near the riverbank."),
    ("en-technical", "en", "Samantha",
     "Push the branch to GitHub and open a pull request against main, "
     "then merge it once the checks are green."),
    ("en-numbers", "en", "Samantha",
     "The meeting is at four thirty on March fifteenth, in room two hundred and twelve."),
    ("en-longform", "en", "Samantha",
     "I was thinking about the transcription pipeline this morning and I realized "
     "that the real cost is not the model size but the time it takes to load and "
     "warm up before the very first word is recognized, which is what people "
     "actually feel when they use it."),
    ("zh-plain", "zh", "Tingting",
     "今天天气很好，我们下午去公园散步吧。"),
    ("zh-technical", "zh", "Tingting",
     "请把这个分支推送到远程仓库，然后创建一个合并请求。"),
]


@dataclass
class Sample:
    path: Path
    language: str
    reference: str
    duration: float
    synthetic: bool

    @property
    def name(self) -> str:
        return self.path.stem

    @property
    def char_scored(self) -> bool:
        return self.language in CHAR_SCORED


@dataclass
class Result:
    sample: Sample
    hypothesis: str
    seconds: float
    error_rate: float


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------- generation

def generate_samples() -> None:
    """Synthesize the starter corpus with `say` -> 16 kHz mono WAV."""
    SAMPLES.mkdir(parents=True, exist_ok=True)
    for name, language, voice, text in SYNTH_SAMPLES:
        wav = SAMPLES / f"{name}.wav"
        if wav.exists():
            print(f"  skip {wav.name} (exists)")
            continue
        aiff = SAMPLES / f"{name}.aiff"
        say = subprocess.run(["say", "-v", voice, "-o", str(aiff), text],
                             capture_output=True, text=True)
        if say.returncode != 0:
            print(f"  SKIP {name}: voice '{voice}' unavailable "
                  f"(System Settings -> Accessibility -> Spoken Content)")
            continue
        # WhisperKit resamples internally, but 16 kHz mono is what the mic path
        # feeds it -- keep the bench on the same footing as real dictation.
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                        str(aiff), str(wav)], check=True, capture_output=True)
        aiff.unlink()
        (SAMPLES / f"{name}.txt").write_text(text + "\n", encoding="utf-8")
        # .synthetic marks these as TTS so the report can flag them.
        (SAMPLES / f"{name}.synthetic").touch()
        print(f"  wrote {wav.name}")


def load_samples() -> list[Sample]:
    samples: list[Sample] = []
    for wav in sorted(SAMPLES.glob("*.wav")):
        reference_file = wav.with_suffix(".txt")
        if not reference_file.exists():
            print(f"  skip {wav.name}: no {reference_file.name} reference")
            continue
        language = wav.stem.split("-", 1)[0] if "-" in wav.stem else "en"
        with wave.open(str(wav)) as handle:
            duration = handle.getnframes() / handle.getframerate()
        samples.append(Sample(
            path=wav,
            language=language,
            reference=reference_file.read_text(encoding="utf-8").strip(),
            duration=duration,
            synthetic=wav.with_suffix(".synthetic").exists(),
        ))
    return samples


# ------------------------------------------------------------------- scoring

NUMBER_WORDS = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
    "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
    "ninety": 90, "hundred": 100, "thousand": 1000, "million": 1000000,
    # Ordinals -- "March fifteenth" vs "March 15" is a spelling difference.
    "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
    "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
    "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
    "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
    "twentieth": 20, "thirtieth": 30,
}
MULTIPLIERS = {100, 1000, 1000000}


def _resolve_number_run(values: list[int]) -> str:
    """Fold a run of number words into the digits a model would have written.

    "two hundred and twelve" -> 212, but "four thirty" -> 430 (a time, not 34),
    and "nineteen eighty four" -> 1984. Plain adjacent numbers concatenate;
    only hundred/thousand actually multiply.
    """
    parts: list[int] = []
    current = 0
    for value in values:
        if value in MULTIPLIERS:
            current = max(current, 1) * value
        elif current and current % 100 == 0:
            current += value          # "two hundred [and] twelve" -> 212
        elif current and value < 10 and current % 10 == 0:
            current += value          # "eighty four" -> 84, "twenty six" -> 26
        elif current:
            parts.append(current)     # "four thirty" -- two separate numbers
            current = value
        else:
            current = value
    parts.append(current)
    return "".join(str(p) for p in parts)


def canonicalize_numbers(tokens: list[str]) -> list[str]:
    """Put spelled-out and digit numbers into the same form before scoring.

    Without this, a model that writes "4:30" where the reference says "four
    thirty" is charged three errors for being right.
    """
    out: list[str] = []
    run: list[int] = []

    def flush() -> None:
        if run:
            out.append(_resolve_number_run(run))
            run.clear()

    for token in tokens:
        if token in NUMBER_WORDS:
            run.append(NUMBER_WORDS[token])
        elif token == "and" and run:
            continue                  # "two hundred AND twelve"
        elif token.isdigit():
            run.append(int(token))
        else:
            flush()
            out.append(token)
    flush()
    return out


def normalize(text: str, char_scored: bool) -> list[str]:
    """Lowercase, drop punctuation, split into scoring units.

    Punctuation is excluded on purpose: it comes from the cleanup stage, not
    the ASR stage, so scoring it here would measure the wrong thing.
    """
    text = unicodedata.normalize("NFKC", text).lower()
    text = "".join(" " if unicodedata.category(c).startswith("P") else c for c in text)
    text = re.sub(r"\s+", " ", text).strip()
    if char_scored:
        return [c for c in text if not c.isspace()]
    return canonicalize_numbers(text.split())


def error_rate(reference: list[str], hypothesis: list[str]) -> float:
    """Levenshtein distance / reference length -- WER or CER by unit."""
    if not reference:
        return 0.0 if not hypothesis else 1.0
    previous = list(range(len(hypothesis) + 1))
    for i, ref_token in enumerate(reference, start=1):
        current = [i]
        for j, hyp_token in enumerate(hypothesis, start=1):
            current.append(min(
                previous[j] + 1,                                  # deletion
                current[j - 1] + 1,                               # insertion
                previous[j - 1] + (ref_token != hyp_token),       # substitution
            ))
        previous = current
    return previous[-1] / len(reference)


# ----------------------------------------------------------------- execution

LOADED_RE = re.compile(r"Model loaded in ([\d.]+)s")
TRANSCRIBED_RE = re.compile(r"Transcribed in ([\d.]+)s: (.*)", re.DOTALL)
RSS_RE = re.compile(r"^\s*(\d+)\s+maximum resident set size", re.MULTILINE)


def run_model(model: str, samples: list[Sample]) -> tuple[list[Result], float, float]:
    """Transcribe every sample with `model`. Returns (results, load_s, peak_gb).

    One process per sample: that's the honest number for LocalFlow's *first*
    dictation, and it keeps a crashed model from taking the whole run with it.
    """
    results: list[Result] = []
    load_seconds = 0.0
    peak_bytes = 0

    for sample in samples:
        command = ["/usr/bin/time", "-l", str(BINARY),
                   "--transcribe", str(sample.path),
                   "--model", model,
                   "--language", sample.language]
        started = time.monotonic()
        proc = subprocess.run(command, capture_output=True, text=True)
        wall = time.monotonic() - started
        if proc.returncode != 0:
            print(f"    {sample.name}: FAILED\n{proc.stdout.strip()[:400]}")
            continue

        if load_match := LOADED_RE.search(proc.stdout):
            load_seconds = max(load_seconds, float(load_match.group(1)))
        if rss_match := RSS_RE.search(proc.stderr):
            peak_bytes = max(peak_bytes, int(rss_match.group(1)))

        transcribed = TRANSCRIBED_RE.search(proc.stdout)
        if not transcribed:
            print(f"    {sample.name}: no transcript in output (wall {wall:.1f}s)")
            continue
        seconds, hypothesis = float(transcribed.group(1)), transcribed.group(2).strip()
        rate = error_rate(
            normalize(sample.reference, sample.char_scored),
            normalize(hypothesis, sample.char_scored),
        )
        results.append(Result(sample, hypothesis, seconds, rate))
        unit = "CER" if sample.char_scored else "WER"
        print(f"    {sample.name:<16} {unit} {rate:6.1%}  {seconds:5.2f}s "
              f"({sample.duration / seconds:5.1f}x realtime)")

    return results, load_seconds, peak_bytes / 1e9


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--generate", action="store_true",
                        help="synthesize the starter sample set with `say`, then exit")
    parser.add_argument("--models", default=",".join(DEFAULT_MODELS),
                        help="comma-separated WhisperKit model ids")
    parser.add_argument("--json", type=Path,
                        help="also write the full results (incl. transcripts) here")
    args = parser.parse_args()

    if args.generate:
        print(f"Generating starter samples in {SAMPLES.relative_to(REPO)}/")
        generate_samples()
        print("\nDone. Record your OWN voice saying the same lines "
              "(same <lang>-<name>.wav + .txt naming) to get numbers that "
              "predict your real dictation.")
        return 0

    if not BINARY.exists():
        die(f"{BINARY.relative_to(REPO)} not found -- run `make bundle` first")

    samples = load_samples()
    if not samples:
        die(f"no samples in {SAMPLES.relative_to(REPO)}/ -- run `make bench-init` first")

    synthetic = sum(s.synthetic for s in samples)
    total_audio = sum(s.duration for s in samples)
    print(f"{len(samples)} samples, {total_audio:.1f}s of audio "
          f"({synthetic} synthesized, {len(samples) - synthetic} real)")
    if synthetic == len(samples):
        print("NOTE: every sample is TTS. Clean studio speech -- these error "
              "rates are a floor, not a prediction for your voice.")

    rows, payload = [], {}
    for model in args.models.split(","):
        print(f"\n{model}")
        results, load_seconds, peak_gb = run_model(model, samples)
        if not results:
            print("    no usable results")
            continue
        mean_error = sum(r.error_rate for r in results) / len(results)
        transcribe_seconds = sum(r.seconds for r in results)
        rows.append((model, mean_error, load_seconds, transcribe_seconds,
                     total_audio / transcribe_seconds, peak_gb))
        payload[model] = {
            "mean_error_rate": mean_error,
            "load_seconds": load_seconds,
            "peak_rss_gb": peak_gb,
            "samples": [{"name": r.sample.name, "language": r.sample.language,
                         "error_rate": r.error_rate, "seconds": r.seconds,
                         "reference": r.sample.reference, "hypothesis": r.hypothesis}
                        for r in results],
        }

    if not rows:
        die("every model failed -- see output above")

    print(f"\n{'model':<32} {'err':>7} {'load':>7} {'total':>7} {'speed':>9} {'peak RAM':>9}")
    print("-" * 76)
    for model, mean_error, load_seconds, transcribe_seconds, speed, peak_gb in rows:
        print(f"{model:<32} {mean_error:6.1%} {load_seconds:6.1f}s "
              f"{transcribe_seconds:6.1f}s {speed:8.1f}x {peak_gb:8.2f}GB")

    print("\nload  = one-time on first use per model, and includes DOWNLOAD + ANE "
          "compile the very first time. Re-run for steady-state numbers.")
    print("peak RAM = process RSS, which UNDERSTATES CoreML/ANE models: weights "
          "live outside this process. Compare models with it, don't size a Mac by it.")

    best = min(rows, key=lambda r: r[1])
    fastest = max(rows, key=lambda r: r[4])
    print(f"\nlowest error: {best[0]} ({best[1]:.1%})")
    print(f"fastest:      {fastest[0]} ({fastest[4]:.1f}x realtime, {fastest[1]:.1%} error)")
    if best[0] != fastest[0]:
        print("Cost-efficiency is the trade between those two -- for push-to-talk "
              "dictation, latency is felt on every use; accuracy only on the words it misses.")

    if args.json:
        args.json.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"\nWrote {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
