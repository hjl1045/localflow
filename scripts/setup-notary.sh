#!/bin/bash
# One-time setup for notarizing LocalFlow builds you install yourself.
#
# Notarization needs two things that only you can create, because both require
# signing in to your Apple Developer account:
#
#   1. A "Developer ID Application" certificate in your keychain.
#      An "Apple Development" certificate CANNOT notarize — different purpose.
#   2. Notary credentials stored in the keychain, so `make notarize` can submit
#      without a password prompt every time.
#
# This script checks (1), then walks you through (2). Run it once:
#   bash scripts/setup-notary.sh

set -uo pipefail
PROFILE="${NOTARY_PROFILE:-localflow-notary}"

say() { printf '\n%s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# --- 1. The certificate -------------------------------------------------------
say "Looking for a Developer ID Application certificate..."
DEVID=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application/{print $2; exit}')

if [ -z "$DEVID" ]; then
  cat <<'MSG'

No "Developer ID Application" certificate found.

Create it in Xcode (easiest — it generates the key and CSR for you):
  Xcode > Settings… > Accounts > select your team
    > Manage Certificates… > the + button > "Developer ID Application"

It appears in your keychain within a few seconds. Then run this script again.

If the + menu doesn't offer it, your Apple ID may lack the Admin/Account Holder
role on the team — only those roles can issue Developer ID certificates.
MSG
  exit 1
fi

say "Found: $DEVID"

# The Team ID is the parenthesised suffix of the certificate name.
TEAM_ID=$(printf '%s' "$DEVID" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')
[ -n "$TEAM_ID" ] || fail "couldn't parse a Team ID out of: $DEVID"
say "Team ID: $TEAM_ID"

# --- 2. Notary credentials ----------------------------------------------------
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  say "Notary credentials '$PROFILE' already work. Nothing to do."
  say "You can now run:  make install-notarized"
  exit 0
fi

cat <<MSG

Now the notary credentials, stored in your keychain as "$PROFILE".

You need an APP-SPECIFIC PASSWORD — not your normal Apple ID password. Create
one at:

  https://account.apple.com  >  Sign-In and Security  >  App-Specific Passwords

Name it something like "notarytool". Copy it (format: xxxx-xxxx-xxxx-xxxx).
It is stored in your keychain, never in this repo.

MSG

printf 'Apple ID (the email on your Developer account): '
read -r APPLE_ID
[ -n "$APPLE_ID" ] || fail "no Apple ID entered"

say "notarytool will now ask for the app-specific password (input is hidden)."
xcrun notarytool store-credentials "$PROFILE" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  || fail "store-credentials failed — check the Apple ID and app-specific password"

# --- 3. Prove it actually works ----------------------------------------------
say "Verifying the credentials against Apple's notary service..."
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  say "Credentials work. Now run:  make install-notarized"
else
  fail "credentials were stored but the notary service rejected them"
fi
