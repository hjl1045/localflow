# Distributing LocalFlow

LocalFlow is an Apple-Silicon-only, on-device menu-bar app. This covers getting
it onto another Mac, and publishing a release on GitHub — the one public
distribution channel.

## 1. Install on another Mac (build from source) — recommended

Simplest and least friction: a locally built app isn't quarantined, so there's
no Gatekeeper prompt and no signing to manage. Both machines must be **Apple
Silicon**.

```sh
xcode-select --install                            # once, if no build tools
git clone https://github.com/hjl1045/localflow.git
cd localflow && make install                      # builds, installs to /Applications, launches it
```

Then grant **Microphone + Accessibility** when prompted. The Whisper model
auto-downloads (~626 MB) on first run; Ollama is optional (`brew install ollama
&& ollama pull gemma3:4b`).

## 2. Download a release

The prebuilt route: download `LocalFlow-<version>.zip` from
[GitHub Releases](https://github.com/hjl1045/localflow/releases/latest), unzip,
drag `LocalFlow.app` to Applications, and double-click. Releases from v0.2.2 on are
notarized, so there's no Gatekeeper dialog and nothing to strip.

Don't copy `dist.noindex/LocalFlow.app` to another Mac instead — that's the
Apple-Development-signed local build, not the notarized one, so a quarantined copy
of it *will* be blocked.

## 2b. Managed / work Macs — install without touching `/Applications`

```sh
make install-user      # -> ~/Applications/LocalFlow.app
make uninstall-user
```

`LSUIElement` is already `true`, so LocalFlow has no Dock icon and is already a
background menu-bar service. `install-user` changes **only where the bundle
lives** — same binary, same signature, same bundle id, so Microphone and
Accessibility behave the same. It needs no admin rights and writes nothing
outside the home folder.

Install one or the other per machine, never both: two copies sharing
`ai.xdlab.LocalFlow` leave LaunchServices and TCC ambiguous about which bundle
a hotkey or login item refers to.

### What this fixes, and what it doesn't

A location change is not a way around managed-Mac policy. It helps with exactly
one class of problem and no others.

| Symptom | Does `install-user` help? |
|---|---|
| Needs an admin password to install; IT watches writes to `/Applications` | **Yes** — nothing outside `$HOME` is written |
| "LocalFlow is damaged and can't be opened" after copying a **downloaded** zip | **No**, and since 2026-09-12 it shouldn't happen at all — release artifacts are notarized and stapled, so a quarantined download passes Gatekeeper. **v0.2.1 and earlier are ad-hoc signed** and do show it; v0.2.2 is the first notarized release. On those: `xattr -dr com.apple.quarantine <path>/LocalFlow.app`, or upgrade |
| "cannot be opened because the developer cannot be verified" | **No** — and fixed from v0.2.2. v0.2.1 and earlier are ad-hoc signed and do show this: same `xattr` fix, or build from source |
| MDM policy requiring notarized / allow-listed apps (Jamf, Santa, CrowdStrike…) | **No** — the policy is about the signature, not the path. Use `make install-notarized-user` instead (§2c), or have IT allow-list it |
| Microphone or Accessibility toggle won't stick, or the app isn't offered in System Settings | **No** — that's a managed **PPPC** profile. Only IT can grant it |

So: if the blocker is *where the file goes*, this fixes it. If the blocker is
*what the binary is signed with*, nothing local fixes it — that needs
notarization (see §3) or an IT allow-list entry.

### Diagnosing which one you're hitting

The exact wording matters, and Console shows what the dialog hides:

```sh
xattr -p com.apple.quarantine /path/to/LocalFlow.app 2>/dev/null && echo "QUARANTINED"
spctl -a -vvv /path/to/LocalFlow.app          # Gatekeeper's own verdict
codesign -dvvv /path/to/LocalFlow.app 2>&1 | grep -E 'Signature|TeamIdentifier'
log show --last 5m --predicate 'subsystem == "com.apple.TCC"' | grep -i localflow
sudo profiles list                             # is the Mac MDM-managed at all?
```

### Known unverified

Whether **launch at login** works from `~/Applications` has not been confirmed.
`SMAppService.mainApp.status` is keyed to the *bundle identifier*, not the path,
so on a machine that has ever had a `/Applications` copy it reports the same
answer for both and can't distinguish them. On a machine with only the
user-level install, flip the Settings toggle once and check that it survives a
reboot.

## 2c. Notarized builds — for your machines and for public releases

```sh
bash scripts/setup-notary.sh     # once: checks the certificate, stores credentials
make install-notarized           # → /Applications   (the normal one)
make install-notarized-user      # → ~/Applications  (managed Mac that won't take /Applications)
```

Both sign with Developer ID + hardened runtime, notarize, staple, and install.
**Install one or the other, never both** — two copies of
the same bundle id leave LaunchServices and TCC unable to tell which one a
permission grant belongs to.

⚠️ **Neither of these installs a published release**, despite how
`install-notarized` reads. They rebuild from source, stamp the result a dev
build and send it through the notary again — a round-trip you don't need, and a
binary that is not the one on GitHub and whose `.dSYM` was never archived, so a
crash from it can't be symbolicated. To get onto a release, use
`make install-release` ([RELEASING.md](RELEASING.md) §7); it downloads rather
than builds, needs no certificate or notary credential, and refuses anything
that isn't Developer ID signed, stapled and Gatekeeper-accepted.

Re-installing over a copy signed with the **same** Developer ID keeps the
Microphone and Accessibility grants, since TCC keys them to the code signature;
`install-notarized` inspects the outgoing copy and tells you which case you're
in rather than always warning. An identity change (Apple Development →
Developer ID, or a reissued certificate) *may* void them — but measured
2026-09-20 it didn't, so test dictation before re-granting anything. See
"The signature change may or may not cost you your permissions" below.

A notarized, stapled app passes Gatekeeper anywhere — including a managed Mac
that refuses un-notarized software. This is the answer to the "MDM requires
notarized apps" row in §2b, the one thing a location change can't fix.

### Public releases are notarized too (decided 2026-09-12)

They weren't, for a year. A **Developer ID** signature embeds the signing
identity in the binary and `codesign -dvvv` prints it to anyone who downloads
the app — so `make zip` used to re-sign ad-hoc, stripping the identity the way
[THE-178](https://linear.app/the-autonomes/issue/THE-178) cleaned it out of the commit history. Anonymous distribution and
frictionless install looked mutually exclusive.

The organisation enrollment dissolved most of that. The certificate reads
**`Developer ID Application: The Autonomes Technologies LLC`**, not a personal
name or email, so what a downloader learns is the org — which is already public.
Weighed against a first launch that needs no `xattr` incantation, the trade went
the other way:

| | signature | identity visible to a downloader |
|---|---|---|
| `make zip` → GitHub Release | Developer ID + notarized + stapled | yes — the organisation name |
| `make install-notarized[-user]` → your own Mac | same | same |

Both paths are now the same artifact shape, which is also one fewer thing to get
wrong. The cost is a notary round-trip per release, so `zip` depends on
`notarize`, and it refuses to package anything that isn't Developer ID signed,
hardened-runtime, and stapled — an unstapled artifact fails on the downloader's
Mac, not on yours. It ends by unzipping its own output and asking `spctl` for
Gatekeeper's verdict on the copy a stranger would get.

### ⚠️ If the notary credential keeps vanishing

It vanished three times — 2026-09-08, then twice on 2026-09-12, the last time blocking a
release — each within minutes of a successful notarization, with the login keychain
unlocked (`no-timeout`) and no `make clean` or reboot in between.

Cause, most likely: `notarytool store-credentials` **defaults to the "Local Items" /
iCloud keychain**, per its own `--help`. Items there are invisible to
`security find-generic-password` (which is why "the item is absent" was weaker evidence
than it looked) and subject to Local Items / iCloud eviction.

So `setup-notary.sh` now passes `--keychain ~/Library/Keychains/login.keychain-db`, and
the Makefile passes the same path on every `notarytool` call.

**`--keychain` genuinely selects the store** — verified by pointing a read at a different
keychain file and at a nonexistent path, both of which correctly fail:

```sh
xcrun notarytool history --keychain-profile localflow-notary \
  --keychain ~/Library/Keychains/login.keychain-db    # found
xcrun notarytool history --keychain-profile localflow-notary \
  --keychain ~/Library/Keychains/openvpn.keychain-db  # not found
```

⚠️ `security find-generic-password -s com.apple.gke.notary.tool` does **not** find the item
even when it is present — notarytool stores it under attributes that query doesn't match.
Use the `notarytool` read above as the check; `security` returning nothing proves nothing
in either direction.

**This is a hypothesis with good mechanism support, not a proven fix** — it needs a few
days of surviving normal use before it's believed. Until then, pre-flight before anything
that depends on it:

```sh
xcrun notarytool history --keychain-profile localflow-notary \
  --keychain ~/Library/Keychains/login.keychain-db >/dev/null && echo ok
```

Recovery always needs the Apple ID app-specific password, so it is a stop-and-ask failure,
never something a script can retry.

### One-time setup

1. **The certificate** — Xcode > Settings… > Accounts > your team > Manage
   Certificates… > **+** > **Developer ID Application**. An *Apple Development*
   certificate cannot notarize; it's a different kind. Only the Admin or Account
   Holder role on the team can issue one.
2. **The credentials** — `bash scripts/setup-notary.sh`. It needs an
   **app-specific password** (from account.apple.com > Sign-In and Security >
   App-Specific Passwords), *not* the normal Apple ID password. Stored in the
   keychain as `localflow-notary`; nothing lands in the repo.

### What the target does, and why in that order

- Signs **inside-out** — nested `.bundle` resources first, the app last.
  `--deep` is unsupported for notarization; Apple's advice is to sign nested
  code separately, which is why this doesn't reuse the `bundle` target's
  signing step.
- `--options runtime` (hardened runtime) and `--timestamp` are **required**;
  notarization rejects builds without them.
- `Support/LocalFlow.entitlements` grants
  `com.apple.security.device.audio-input`. The hardened runtime blocks the
  microphone unless the binary asks for it explicitly — without this the app
  launches fine and then records silence, with no prompt.
  `NSMicrophoneUsageDescription` is the reason string shown to the user; the
  entitlement is the capability. Both are needed.
- Asserts the hardened-runtime flag is present **before** submitting, so a build
  that can't pass doesn't cost a notary round-trip.
- Ends with `spctl -a -vvv -t install`, which is Gatekeeper's own verdict on the
  stapled bundle — the only check that actually proves it will open.

### The signature change may or may not cost you your permissions — test, don't pre-empt

macOS ties Microphone and Accessibility grants to the code signature, so
switching from the Apple Development signature to Developer ID *looks* like it
must make this a different app as far as TCC is concerned. This section used to
say both grants stop working.

**Measured 2026-09-20: they didn't.** Replacing an `Apple Development`-signed
copy with the notarized Developer ID build left dictation working immediately —
`AXIsProcessTrusted=true`, microphone capturing, no prompt, no re-grant. Same
bundle id and the same `--identifier` on both signatures.

So: **try dictating before you touch System Settings.** One observation isn't a
guarantee it always survives, but re-granting on principle is busywork, and
remove-then-re-add is itself disruptive. If it genuinely doesn't work, remove
LocalFlow from System Settings > Privacy & Security > **Microphone** and >
**Accessibility** with the − button, then re-add it — a stale entry can display
as granted while the API still reports untrusted, so remove-then-re-add rather
than toggling.

## 3. Publish a release on GitHub

**GitHub Releases is the only public distribution channel** (decided 2026-09-12).
People download the zip, unzip it, and drag the app to Applications — and since
v0.2.2 that works by double-clicking, because releases are notarized.

**The procedure lives in [RELEASING.md](RELEASING.md)** — version numbering, the
notary pre-flight, why the version bump is merged before the tag is created,
publishing both assets, verifying the download rather than the build tree, and
the traps that have cost time. It is a checklist; this section is the policy
behind it.

**Release vs dev builds.** Only `make zip` makes a release build (and
`install-release`, which installs one rather than building it). Every other
target (`install`, `install-notarized`, `run`, `bench`) keeps the release's
version number but stamps the bundle with a dev build number, such as
`6-dev-cf1123f` (plus `-dirty` with uncommitted changes). Settings then shows
"LocalFlow 0.2.4 (dev cf1123f)", and crash reports carry the same build number.
So a local build of `main` can't be mistaken for the release it shares a
version with. `make zip` refuses to package a bundle carrying a dev build number.

Publishing a release is also what makes the in-app **Check for updates…** offer
it to everyone on an older version.

### Why not Homebrew

Considered and declined on 2026-09-12.

**The official `homebrew-cask` repository is closed to LocalFlow for now.** Its
notability audit (`brew audit --new`, in `Library/Homebrew/utils/shared_audits.rb`)
requires ≥75 stars **or** ≥30 forks **or** ≥30 watchers, and **triples** those
thresholds for a self-submitted app — so ≥225 stars. At the time LocalFlow had
0 / 0 / 0. That is an automatic rejection, not a review judgment.

**A personal tap** (`hjl1045/homebrew-localflow`) has no notability rule and would
have worked, but she chose not to maintain one: it's a second public repository,
and a pinned `version` + `sha256` that must be bumped on every release or installs
break. GitHub Releases alone carries none of that upkeep.

Worth knowing if this is ever revisited: `brew install --cask --no-quarantine`
**no longer exists** (measured 2026-07-19, Homebrew 6.0.11), so an un-notarized
cask used to require a manual `xattr` step. Notarized releases removed that
problem, which is the only thing that would make a cask worth reconsidering.

## Appendix — `make zip` (release artifact)

`make zip` is already in the `Makefile`. It depends on `notarize`, packages the
**notarized, stapled** bundle with `ditto` (plain `zip` can corrupt a signed
bundle), and refuses to package anything that isn't Developer ID signed,
hardened-runtime and stapled. It emits **two** files:

| File | Upload to the Release? | Why |
| -- | -- | -- |
| `dist.noindex/LocalFlow-<version>.zip` | yes | the app — Developer ID, notarized, stapled; its `sha256` is printed after it's written |
| `dist.noindex/LocalFlow-<version>.dSYM.zip` | **yes** | without it, a crash report from this build is unreadable |

The dSYM matters because the release build is optimized: symbol names exist
only in the `.dSYM`, and `swift build` overwrites it on the next build. The
shipped v0.2.1 had no surviving dSYM anywhere on the build machine, so crash
reports from it can't be symbolicated at all. The target prints the UUIDs it
archived — a report only matches symbols with the same UUID.

Symbolicating with it: [FEEDBACK.md](FEEDBACK.md).
