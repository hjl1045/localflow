#!/bin/bash
# Regenerates an .icns from an SF Symbol glyph (make-icon.swift). Run once when
# the icon design changes; the results are committed so a normal `make` build
# doesn't need to regenerate them.
#
#   ./make-icon.sh                              -> AppIcon.icns      (mic.fill)
#   ./make-icon.sh CheckUpdatesIcon arrow.triangle.2.circlepath
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:-AppIcon}"
SYMBOL="${2:-mic.fill}"

MASTER="$(mktemp -t localflow-icon-XXXX).png"
swift "$DIR/make-icon.swift" "$MASTER" "$SYMBOL"

ICONSET="$DIR/$NAME.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s"             "$MASTER" --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
  sips -z "$((s*2))" "$((s*2))" "$MASTER" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$DIR/$NAME.icns"
rm -rf "$ICONSET" "$MASTER"
echo "wrote $DIR/$NAME.icns"
