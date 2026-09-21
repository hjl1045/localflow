# Cutting a release

The whole procedure, in order. `docs/DISTRIBUTION.md` explains *why* releases
are notarized and GitHub-only; this is what to actually do.

**Merging to `main` does not update the published artifact.** Until a release is
cut, everyone downloading from GitHub keeps getting the previous binary, however
many fixes have landed.

## The short version

```
0. pick the version      minor for capability, patch for fixes
1. pre-flight the notary credential      ← can only be fixed by Hansee
2. verify the build      make test-ish checks + the app's own harnesses
3. bump + MERGE the version commit       ← before tagging, not after
4. make zip              notarized, stapled, + dSYM
5. gh release create     BOTH assets, --target main
6. verify the download   not the build tree
7. make install-release  put this Mac on the published build
8. Linear + docs/QUESTIONS.md
```

---

## 0. Pick the version

`Support/Info.plist` holds `CFBundleShortVersionString` (`0.3.0`) and an integer
`CFBundleVersion` (`7`). The Makefile reads `VERSION` from the first, so every
downstream filename follows automatically. Bump the integer every time.

- **Minor** (`0.2.4` → `0.3.0`) when the release adds a capability users will
  notice. v0.3.0 was esc-to-cancel plus hands-free auto-stop.
- **Patch** (`0.2.3` → `0.2.4`) for fixes, wording and internals.

## 1. Pre-flight the notary credential

**Do this before anything else.** The `localflow-notary` keychain profile has
vanished three times, and recovering it needs an Apple ID app-specific password
— so it is a *stop and ask Hansee* failure, never something to retry around.

```sh
xcrun notarytool history --keychain-profile localflow-notary --keychain ~/Library/Keychains/login.keychain-db >/dev/null && echo ok
```

Not ok → `bash scripts/setup-notary.sh`, which will prompt for that password.

`security find-generic-password -s com.apple.gke.notary.tool` is **useless** here
— it finds nothing even when the credential is present. The `notarytool` read
above is the only valid check.

## 2. Verify the build

A release is the worst place to discover a regression. Run whatever the change
touched, plus the app's own harnesses:

```sh
swift build && .build/debug/LocalFlow --silence-selftest
```

```sh
make bundle && perl -e 'alarm 30; exec @ARGV' dist.noindex/LocalFlow.app/Contents/MacOS/LocalFlow --open-settings
```

The Settings harness catches the SwiftUI layout-loop crash class that has hit
this window twice. A pass means *no regression*, never "fixed" — see
`docs/FEEDBACK.md`.

## 3. Bump the version and merge it — before tagging

```sh
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.3.0' -c 'Set :CFBundleVersion 7' Support/Info.plist
```

Then branch → commit → PR → **merge**. The tag in step 5 points at `main`, so if
the bump is still sitting on a branch the release ships the *previous* version
number while claiming to be the new one.

## 4. Build the artifact

```sh
make zip
```

Produces `dist.noindex/LocalFlow-<version>.zip` **and
`…-<version>.dSYM.zip`**. It depends on `notarize`, so it costs a notary
round-trip — usually minutes, once 57. Don't treat slowness as failure before
about an hour.

It packages the *notarized, stapled* bundle directly. **Do not re-sign the
output** — that invalidates the ticket. It refuses to package a bundle carrying
a dev build number, asserts Developer ID + hardened runtime + stapled ticket,
then unzips its own output and runs `spctl` on the extraction.

⚠️ `make zip` **deletes `dist.noindex/verify/`** when it finishes — extract
elsewhere (a scratch dir) if you want to poke at the result.

## 5. Publish

Write the notes to a file first, then one command. **Upload both assets** — the
dSYM is the only way a crash report from this build is ever symbolicatable, and
`swift build` overwrites it on the next build.

```sh
GH_TOKEN="$(gh auth token --user hjl1045)" gh release create v0.3.0 dist.noindex/LocalFlow-0.3.0.zip dist.noindex/LocalFlow-0.3.0.dSYM.zip --title "v0.3.0 — …" --notes-file notes.md --latest --target main
```

`--target main` is what stops the tag landing on a stale default branch. The
`GH_TOKEN=` prefix picks the right account without disturbing `gh`'s global
state.

**Notes are for downloaders.** Lead with what changed for them and any honest
limit; the engineering story belongs in the Linear issue and the PR.

## 6. Verify what strangers receive

Reading `dist.noindex/` proves nothing about what is actually published.

```sh
gh release download v0.3.0 -D /tmp/lf && shasum -a 256 /tmp/lf/LocalFlow-0.3.0.zip
```

That sha256 must match the one `make zip` printed. Then extract it and check the
extracted copy — `spctl -a -vv -t install`, `xcrun stapler validate`, and run its
CLI (`--silence-selftest`, `--transcribe bench/samples/en-plain.wav`) so the
shipped binary is known to work, not merely to be signed.

## 7. Put this Mac on the published build

```sh
make install-release
```

Downloads the release, refuses anything not Developer ID signed / stapled /
Gatekeeper-accepted / carrying a dev build number **before touching
`/Applications`**, and prints the UUID for matching a future crash report to
that release's dSYM.

⚠️ **Not `make install-notarized`.** Despite the name it rebuilds from source,
stamps the result a dev build and re-notarizes — a second round-trip, and a
binary that is not the published one. That mistake cost an unnecessary
notarization on 2026-09-20. `install-notarized` is for iterating on a
Developer-ID-signed build; `install-release` is for getting onto a release.

The signing identity may change (e.g. `make install` leaves an Apple Development
signature behind). If it does, **test dictation before touching System
Settings** — measured 2026-09-20, both TCC grants survived exactly that swap, so
re-granting on principle is busywork.

## 8. Record it

- **Linear** — the issue for this work gets the release URL, the tag, and the
  verification evidence from step 6.
- **`docs/QUESTIONS.md`** — append the row for whatever question this release
  answered. That file is gitignored (personal working notes), so the edit will
  never show in `git status` and must not be force-added.

---

## Traps that have actually cost time

| Trap | What happens |
|---|---|
| Tagging before merging the version bump | Release ships the old version number under the new tag. |
| `make install-notarized` to "get the release" | Rebuilds + re-notarizes a dev build. Second round-trip, wrong binary, unsymbolicatable dSYM. |
| Forgetting the dSYM asset | v0.2.1 shipped without one anywhere on the build machine; its crash reports are permanently unsymbolicatable. |
| Re-signing `make zip`'s output | Invalidates the notarization ticket. |
| Verifying from `dist.noindex/` | Proves nothing about the published asset. |
| `strings` on the installed binary to check a change landed | Swift stores short literals inline and splits non-ASCII ones; use `cmp` against the artifact instead. |
| Renaming `dist.noindex/` | The `.noindex` suffix is load-bearing — without it macOS registers every build artifact under the same bundle id. |
| Assuming the notary credential is there | It has vanished three times mid-session. Step 1 exists for this. |
