# Distributing LocalFlow

LocalFlow is an Apple-Silicon-only, on-device menu-bar app. This covers getting
it onto another Mac, and (optionally) publishing it via Homebrew.

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

## 2. Copy the prebuilt app

`make zip` (see below) or copy `dist.noindex/LocalFlow.app`, then on the target:

```sh
xattr -dr com.apple.quarantine LocalFlow.app   # it's not notarized
open LocalFlow.app
```

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
| "LocalFlow is damaged and can't be opened" after copying a **downloaded** zip | **No**, and since 2026-09-12 it shouldn't happen at all — release artifacts are notarized and stapled, so a quarantined download passes Gatekeeper. **v0.2.1 and earlier are ad-hoc signed** and do show it — the decision came after v0.2.1 shipped, so the first notarized artifact is the next release. On those: `xattr -dr com.apple.quarantine <path>/LocalFlow.app`, or upgrade |
| "cannot be opened because the developer cannot be verified" | **No** — and fixed for releases after v0.2.1. v0.2.1 and earlier are ad-hoc signed and do show this: same `xattr` fix, or build from source |
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

Both sign with Developer ID + hardened runtime, notarize, staple, and install the
companion app alongside. **Install one or the other, never both** — two copies of
the same bundle id leave LaunchServices and TCC unable to tell which one a
permission grant belongs to.

Re-installing over a copy signed with the **same** Developer ID keeps the
Microphone and Accessibility grants, since TCC keys them to the code signature;
`install-notarized` inspects the outgoing copy and tells you which case you're in
rather than always warning. Grants are only voided when the identity changes —
Apple Development → Developer ID, or a reissued certificate.

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
Weighed against a first launch that needs no `xattr` incantation and a Homebrew
cask that finally works, the trade went the other way:

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

### ⚠️ The signature change voids your existing permissions

macOS ties Microphone and Accessibility grants to the code signature. Switching
from the Apple Development signature to Developer ID makes it a *different* app
as far as TCC is concerned, so **both grants stop working**. Remove LocalFlow
from System Settings > Privacy & Security > **Microphone** and > **Accessibility**
with the − button, then re-add it. A stale entry can display as granted while
the API still reports untrusted, so remove-then-re-add rather than toggling.

## 3. Publish via Homebrew (Cask)

Because it's a GUI `.app`, Homebrew distribution is a **Cask**, not a formula.
A cask downloads a prebuilt artifact from a URL and drops the app in
`/Applications`.

### Prerequisites (important)

- **A public download URL.** Homebrew can't authenticate to a private repo's
  release assets. The repo is public, so release assets are directly
  downloadable — no extra work.
- **Apple Silicon only** — the cask should declare `depends_on arch: :arm64`.
- **Notarization is the real blocker.** See the next section: without it, a cask
  install is *worse* than building from source, and as of Homebrew 6 there is no
  longer a supported flag to work around it.

### The quarantine problem — solved 2026-09-12

This used to be the reason not to publish a cask. Release artifacts were ad-hoc
signed and unnotarized, so Gatekeeper blocked the downloaded app on first
launch, and the advice everyone repeats — `brew install --cask --no-quarantine`
— **does not work, because that flag no longer exists** (measured 2026-07-19,
Homebrew 6.0.11):

```
$ brew install --cask --no-quarantine localflow
Error: invalid option: --no-quarantine
```

A cask user therefore had to run `xattr -dr com.apple.quarantine` by hand, which
is a strictly worse first run than building from source.

**Releases are now notarized and stapled**, so a quarantined download passes
Gatekeeper and opens on a double-click. The blocker is gone and a cask is worth
publishing; the routes below are no longer hypothetical. Keep in mind:

- the ticket must be **stapled**, not merely notarized — stapling is what makes
  the check work offline, and `make zip` asserts it;
- the cask's `sha256` changes with every release, and a stale one makes installs
  fail. Refresh it whenever you cut one (see the release checklist in the
  [FEEDBACK] and [Appendix] sections).

### Route A — your own tap (the path, when you do publish)

You control it end-to-end; users don't need access to the main repo.

1. **Cut a release** with the artifact attached:
   ```sh
   make zip                       # -> dist.noindex/LocalFlow-<version>.zip, notarized + stapled
   shasum -a 256 dist.noindex/LocalFlow-*.zip
   gh release create v0.2.1 dist.noindex/LocalFlow-0.2.1.zip --title "LocalFlow v0.2.1" --notes "…"
   ```
   (For hjl1045 repos, prefix `gh` with `GH_TOKEN="$(gh auth token --user hjl1045)"`.)
2. **Create a tap repo** named `homebrew-localflow` — the `homebrew-` prefix is
   required: `hjl1045/homebrew-localflow`.
3. Add `Casks/localflow.rb`:
   ```ruby
   cask "localflow" do
     version "0.2.1"
     sha256 "e10a99e0c907f4e97781d40b24bd4b8cdcbfcef59e7174bab16f06ceed2a186c"

     url "https://github.com/hjl1045/localflow/releases/download/v#{version}/LocalFlow-#{version}.zip"
     name "LocalFlow"
     desc "Fully-local, on-device dictation for Apple Silicon"
     homepage "https://github.com/hjl1045/localflow"

     depends_on arch: :arm64
     depends_on macos: ">= :sonoma"   # LSMinimumSystemVersion 14.0

     app "LocalFlow.app"

     caveats <<~EOS
       LocalFlow is not notarized, so macOS blocks it on first launch:
         xattr -dr com.apple.quarantine /Applications/LocalFlow.app
       Then grant Microphone and Accessibility when prompted.
     EOS

     zap trash: [
       "~/Library/Preferences/ai.xdlab.LocalFlow.plist",
     ]
   end
   ```
   The `caveats` block is what makes this survivable — Homebrew prints it after
   install, so the user is told about the quarantine step instead of hitting a
   "damaged app" dialog with no explanation.
4. **Install from the tap:**
   ```sh
   brew tap hjl1045/localflow
   brew install --cask localflow          # or: brew install --cask hjl1045/localflow/localflow
   xattr -dr com.apple.quarantine /Applications/LocalFlow.app
   ```
5. **Each update:** `make zip`, cut the release, then bump `version` + `sha256`
   in the cask. The sha256 must match the new artifact or installs fail.

### Route B — official homebrew-cask

Submit a PR to `Homebrew/homebrew-cask`. Higher bar: notarized, stable
versioned releases, some notability, and review. Overkill unless you're
distributing widely. Route A is the pragmatic choice.

### Reality check

For your *own* Macs, **build-from-source (section 1) is simpler than Homebrew** —
no releases, no notarization, no public repo. Homebrew mainly pays off when
sharing with people who won't build from source.

## Appendix — `make zip` (release artifact)

`make zip` is already in the `Makefile`. It depends on `notarize`, packages the
**notarized, stapled** bundle with `ditto` (plain `zip` can corrupt a signed
bundle), and refuses to package anything that isn't Developer ID signed,
hardened-runtime and stapled. It emits **two** files:

| File | Upload to the Release? | Why |
| -- | -- | -- |
| `dist.noindex/LocalFlow-<version>.zip` | yes | the app — Developer ID, notarized, stapled; the cask's `sha256` is printed after it's written |
| `dist.noindex/LocalFlow-<version>.dSYM.zip` | **yes** | without it, a crash report from this build is unreadable |

The dSYM matters because the release build is optimized: symbol names exist
only in the `.dSYM`, and `swift build` overwrites it on the next build. The
shipped v0.2.1 had no surviving dSYM anywhere on the build machine, so crash
reports from it can't be symbolicated at all. The target prints the UUIDs it
archived — a report only matches symbols with the same UUID.

Symbolicating with it: [FEEDBACK.md](FEEDBACK.md).
