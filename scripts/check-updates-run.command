#!/bin/bash
# Double-clickable entry point for the update check: runs it in a Terminal
# window and keeps the window open so the report is actually readable.
# "Check Model Updates.app" (see `make check-updates-app`) is a wrapper around
# this file — it exists to give the same thing a Dock icon.
cd "$(dirname "$0")/.." || exit 1

python3 scripts/check-updates.py
status=$?

echo
if [ $status -ne 0 ]; then
  echo "check-updates exited $status (network or parse error)"
fi
read -n 1 -s -r -p "Press any key to close this window…"
echo
