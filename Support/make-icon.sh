#!/bin/bash
# Regenerates Support/AppIcon.icns from the SF Symbol mic glyph (make-icon.swift).
# Run once when the icon design changes; the resulting .icns is committed so a
# normal `make` build doesn't need to regenerate it.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

MASTER="$(mktemp -t localflow-icon-XXXX).png"
swift "$DIR/make-icon.swift" "$MASTER"

ICONSET="$DIR/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s"             "$MASTER" --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
  sips -z "$((s*2))" "$((s*2))" "$MASTER" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$DIR/AppIcon.icns"
rm -rf "$ICONSET" "$MASTER"
echo "wrote $DIR/AppIcon.icns"
