#!/bin/bash
# Bundle launcher for "Check Model Updates.app". @REPO@ is substituted with the
# repo path at build time (`make check-updates-app`), so the .app can live in
# /Applications or the Dock while the scripts stay in the repo.
REPO="@REPO@"
RUNNER="$REPO/scripts/check-updates-run.command"

if [ ! -x "$RUNNER" ]; then
  osascript -e "display alert \"LocalFlow update check\" message \"Can't find $RUNNER — the repo moved. Re-run 'make check-updates-app' from the repo to rebuild this launcher.\" as critical"
  exit 1
fi

exec open -a Terminal "$RUNNER"
