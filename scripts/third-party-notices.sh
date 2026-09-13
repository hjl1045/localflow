#!/bin/bash
# Writes THIRD_PARTY_NOTICES.txt for the software linked into LocalFlow's binary.
#
#   scripts/third-party-notices.sh <output-file>
#
# Generated from the dependency sources SwiftPM checked out for THIS build
# (.build/checkouts), so the notices match the exact versions that are linked
# rather than a hand-copied file that drifts the next time a dependency updates.
#
# Why this exists: MIT requires its copyright and permission notice to travel
# with every copy of the software, and Apache-2.0 additionally requires the
# license text plus any NOTICE attribution. WhisperKit and KeyboardShortcuts are
# compiled directly into the binary, and WhisperKit in turn vendors code from
# Hugging Face's swift-transformers (Apache-2.0). v0.2.2 shipped with none of
# these notices — an actual compliance gap in a public release, not a nicety.
#
# It fails loudly if a license file is missing. A dependency bump that renames
# or drops a license file should break the build, not silently ship an
# incomplete notice.
set -euo pipefail

out="${1:?usage: third-party-notices.sh <output-file>}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
checkouts="$repo/.build/checkouts"

fail() { echo "third-party-notices: $*" >&2; exit 1; }
[ -d "$checkouts" ] || fail "no $checkouts — run 'swift build' first"

# First existing file among the candidates, or fail.
pick() {
    local dir="$1"; shift
    for name in "$@"; do
        [ -f "$dir/$name" ] && { echo "$dir/$name"; return; }
    done
    fail "no license file in $dir (looked for: $*)"
}

rule() { printf '%s\n' "================================================================================"; }

whisperkit_license="$(pick "$checkouts/WhisperKit" LICENSE LICENSE.md LICENSE.txt)"
# WhisperKit's NOTICES carries the swift-transformers attribution and the full
# Apache-2.0 text. It isn't optional: without it the vendored Apache code ships
# unattributed.
whisperkit_notices="$(pick "$checkouts/WhisperKit" NOTICES NOTICE NOTICES.md NOTICE.md)"
shortcuts_license="$(pick "$checkouts/KeyboardShortcuts" license LICENSE license.md LICENSE.md)"

{
    cat <<'HEADER'
LocalFlow — third-party notices

LocalFlow is released under the MIT License. It includes the open-source
software listed below, each distributed under its own license terms, which are
reproduced here as those licenses require.

HEADER

    rule
    echo "WhisperKit (Argmax OSS)"
    echo "https://github.com/argmaxinc/WhisperKit"
    rule
    echo
    cat "$whisperkit_license"
    echo
    echo "--- WhisperKit's own third-party notices ---"
    echo
    cat "$whisperkit_notices"
    echo

    rule
    echo "KeyboardShortcuts"
    echo "https://github.com/sindresorhus/KeyboardShortcuts"
    rule
    echo
    cat "$shortcuts_license"
    echo

    rule
    echo "Speech recognition models"
    rule
    cat <<'MODELS'

LocalFlow does not include model weights. On first use it downloads CoreML
conversions of OpenAI's Whisper models directly from Hugging Face
(https://huggingface.co/argmaxinc/whisperkit-coreml), where they are published
under the MIT License. They are credited here as acknowledgement rather than as
software LocalFlow redistributes.

Whisper: https://github.com/openai/whisper
MODELS
} > "$out"

echo "Wrote $out"
