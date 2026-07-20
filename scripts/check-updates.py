#!/usr/bin/env python3
"""Is anything LocalFlow depends on newer upstream than what we pin or run?

Four things move independently, and only one of them shows up in `git status`:

  1. SwiftPM dependencies      -- Package.resolved vs upstream tags
  2. WhisperKit CoreML models  -- new models appearing in argmaxinc/whisperkit-coreml
  3. Alternative ASR engines   -- the watchlist (FluidInference/Parakeet, etc.)
  4. Ollama + its weights      -- the cleanup model's manifest digest, and the CLI

Run it monthly. It answers "did anything change?", NOT "is the new thing
better?" -- that's `make bench`, on your own audio. A model being newer is not
a reason to switch; a bench win is.

    make check-updates
    python3 scripts/check-updates.py --accept   # snapshot today's model lists

Exits 0 always (nothing here is a failure), 1 only on a network/parse error.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SNAPSHOT = Path(__file__).resolve().parent / "model-snapshot.json"
TIMEOUT = 20

# HF repos to watch for new model builds. The pro/ ones are commercial-licence
# (listed so a licence change or an open release doesn't go unnoticed).
WATCHED_REPOS = [
    ("argmaxinc/whisperkit-coreml", "the models LocalFlow actually runs"),
    ("FluidInference/parakeet-tdt-0.6b-v3-coreml", "faster ANE alternative, no zh/ja/ko"),
]

# Ollama models we depend on, as "name:tag".
OLLAMA_MODELS = ["gemma3:4b"]

BULLET, WARN, NEW = "  ·", "  !", "  +"


def http_json(url: str) -> dict | list:
    request = urllib.request.Request(url, headers={"User-Agent": "localflow-check-updates"})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return json.load(response)


def version_key(tag: str) -> tuple:
    """Sort tags numerically so 1.17.0 beats 1.9.4 (lexically it doesn't)."""
    return tuple(int(part) for part in re.findall(r"\d+", tag)[:4] or [0])


# ------------------------------------------------------------ swiftpm deps

def check_dependencies() -> None:
    print("SwiftPM dependencies")
    resolved = json.loads((REPO / "Package.resolved").read_text())
    for pin in resolved["pins"]:
        location, pinned = pin["location"], pin["state"].get("version", "?")
        try:
            output = subprocess.run(["git", "ls-remote", "--tags", "--refs", location],
                                    capture_output=True, text=True, timeout=TIMEOUT).stdout
        except subprocess.TimeoutExpired:
            print(f"{WARN} {pin['identity']}: timed out reaching {location}")
            continue
        tags = [line.rsplit("/", 1)[-1].lstrip("v") for line in output.splitlines() if line]
        # Ignore pre-releases: we don't want to be nagged about 2.0.0-beta.1.
        tags = [t for t in tags if re.fullmatch(r"[\d.]+", t)]
        if not tags:
            print(f"{BULLET} {pin['identity']}: no tags found")
            continue
        latest = max(tags, key=version_key)
        if version_key(latest) > version_key(pinned):
            major = version_key(latest)[0] > version_key(pinned)[0]
            note = "  (major bump -- expect breaking changes)" if major else ""
            print(f"{NEW} {pin['identity']}: {pinned} -> {latest}{note}")
        else:
            print(f"{BULLET} {pin['identity']}: {pinned} (current)")


# ------------------------------------------------------------- hf models

def model_dirs(repo: str) -> tuple[str, set[str]]:
    """Returns (lastModified, set of model subfolders) for a HF repo."""
    data = http_json(f"https://huggingface.co/api/models/{repo}")
    dirs = {name.rsplit("/", 1)[0]
            for name in (sibling["rfilename"] for sibling in data.get("siblings", []))
            if "/" in name}
    # Keep only top-level model folders, not their .mlmodelc innards.
    top = {d.split("/", 1)[0] for d in dirs}
    return data.get("lastModified", "?"), top


def check_models(snapshot: dict, accept: bool) -> dict:
    print("\nASR model repos")
    updated = dict(snapshot)
    for repo, why in WATCHED_REPOS:
        try:
            last_modified, models = model_dirs(repo)
        except (urllib.error.URLError, KeyError, json.JSONDecodeError) as error:
            print(f"{WARN} {repo}: {error}")
            continue
        known = set(snapshot.get(repo, {}).get("models", []))
        added = sorted(models - known)
        print(f"{BULLET} {repo}  (updated {last_modified[:10]}) -- {why}")
        if known and added:
            for model in added:
                print(f"{NEW}   NEW: {model}")
            print("      -> add it to AppState.models and run `make bench` before switching")
        elif not known:
            print(f"      {len(models)} models, first run -- snapshotting as the baseline")
        updated[repo] = {"lastModified": last_modified, "models": sorted(models)}
    if accept:
        SNAPSHOT.write_text(json.dumps(updated, indent=2) + "\n")
        print(f"\nSnapshot written to {SNAPSHOT.relative_to(REPO)}")
    return updated


# ---------------------------------------------------------------- ollama

def check_ollama() -> None:
    print("\nOllama (optional cleanup stage)")
    try:
        client = subprocess.run(["ollama", "--version"], capture_output=True, text=True, timeout=10)
        installed = re.search(r"([\d.]+)", client.stdout + client.stderr)
        installed = installed.group(1) if installed else "?"
    except (FileNotFoundError, subprocess.TimeoutExpired):
        print(f"{BULLET} not installed -- cleanup is optional, skipping")
        return

    try:
        info = subprocess.run(["brew", "info", "--json=v2", "ollama"],
                              capture_output=True, text=True, timeout=60)
        formula = json.loads(info.stdout)["formulae"][0]
        available = formula["versions"]["stable"]
        if version_key(available) > version_key(installed):
            print(f"{NEW} CLI {installed} -> {available}  (brew upgrade ollama)")
        else:
            print(f"{BULLET} CLI {installed} (current)")
    except Exception:
        print(f"{BULLET} CLI {installed} (brew not available for comparison)")

    # `brew upgrade ollama` does NOT restart the running server -- the
    # LaunchAgent keeps serving the old binary, so the upgrade silently doesn't
    # take. Only the server's own /api/version reveals it. (Hit 2026-07-19.)
    try:
        serving = http_json("http://127.0.0.1:11434/api/version").get("version", "?")
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError, OSError):
        print(f"{BULLET} server not running -- cleanup is skipped until "
              f"`brew services start ollama`")
        return
    if version_key(serving) < version_key(installed):
        print(f"{NEW} server is STALE: serving {serving} while the CLI is "
              f"{installed}  (brew services restart ollama)")
    else:
        print(f"{BULLET} server {serving} (matches CLI)")

    # Weights: compare the local manifest digest against the registry's. A
    # retagged model (same name, new weights) is invisible to `ollama list`.
    manifests = Path.home() / ".ollama/models/manifests/registry.ollama.ai/library"
    for reference in OLLAMA_MODELS:
        name, _, tag = reference.partition(":")
        local_path = manifests / name / (tag or "latest")
        if not local_path.exists():
            print(f"{WARN} {reference}: not pulled  (ollama pull {reference})")
            continue
        local = json.loads(local_path.read_text())["config"]["digest"]
        try:
            remote_manifest = http_json(
                f"https://registry.ollama.ai/v2/library/{name}/manifests/{tag or 'latest'}")
            remote = remote_manifest["config"]["digest"]
        except (urllib.error.URLError, KeyError) as error:
            print(f"{WARN} {reference}: registry unreachable ({error})")
            continue
        if local == remote:
            print(f"{BULLET} {reference}: weights current ({local[7:19]})")
        else:
            print(f"{NEW} {reference}: retagged upstream "
                  f"({local[7:19]} -> {remote[7:19]})  (ollama pull {reference})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--accept", action="store_true",
                        help="record today's model lists as the new baseline")
    args = parser.parse_args()

    snapshot = json.loads(SNAPSHOT.read_text()) if SNAPSHOT.exists() else {}
    first_run = not snapshot

    try:
        check_dependencies()
        check_models(snapshot, accept=args.accept or first_run)
        check_ollama()
    except urllib.error.URLError as error:
        print(f"\nnetwork error: {error}", file=sys.stderr)
        return 1

    print("\nAnything marked + is NEWER, not BETTER. Decide with `make bench`.")
    if not args.accept and not first_run:
        print("Re-run with --accept once you've triaged, to stop repeat reports.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
