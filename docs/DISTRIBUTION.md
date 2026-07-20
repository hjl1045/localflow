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

`make zip` (see below) or copy `dist/LocalFlow.app`, then on the target:

```sh
xattr -dr com.apple.quarantine LocalFlow.app   # it's not notarized
open LocalFlow.app
```

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

### The quarantine problem — measured 2026-07-19, Homebrew 6.0.11

Release artifacts here are **ad-hoc signed and not notarized** (deliberately —
an Apple Development signature embeds the developer's email and Team ID in the
binary, see the `zip` target in the Makefile). Gatekeeper therefore blocks the
downloaded app on first launch.

The advice you'll find everywhere is `brew install --cask --no-quarantine`.
**That flag no longer exists:**

```
$ brew install --cask --no-quarantine localflow
Error: invalid option: --no-quarantine
```

So a cask user must clear quarantine by hand after installing:

```sh
brew install --cask hjl1045/localflow/localflow
xattr -dr com.apple.quarantine /Applications/LocalFlow.app
```

That is a strictly worse first-run experience than `make install` from source,
which produces a locally built app that was never quarantined at all.

**Recommendation: don't publish the cask yet.** It only becomes worth doing with
notarization, which needs a paid Apple Developer account ($99/yr): Developer ID
signing → `xcrun notarytool submit --wait` → `xcrun stapler staple`. Note that
notarizing re-introduces the identity-in-binary tradeoff — a Developer ID
signature also carries the team identity, which is unavoidable for a notarized
public app.

### Route A — your own tap (the path, when you do publish)

You control it end-to-end; users don't need access to the main repo.

1. **Cut a release** with the artifact attached:
   ```sh
   make zip                       # -> dist/LocalFlow-<version>.zip, ad-hoc signed
   shasum -a 256 dist/LocalFlow-*.zip
   gh release create v0.2.0 dist/LocalFlow-0.2.0.zip --title "LocalFlow v0.2.0" --notes "…"
   ```
   (For hjl1045 repos, prefix `gh` with `GH_TOKEN="$(gh auth token --user hjl1045)"`.)
2. **Create a tap repo** named `homebrew-localflow` — the `homebrew-` prefix is
   required: `hjl1045/homebrew-localflow`.
3. Add `Casks/localflow.rb`:
   ```ruby
   cask "localflow" do
     version "0.2.0"
     sha256 "32f67a6a9be5b579ebb570f48a4e16eb2fb44fa624460a9ce0147715fc3a4132"

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

Add to the `Makefile` (uses `ditto` so the signed bundle stays intact):

```make
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)

zip: bundle
	ditto -c -k --keepParent $(BUNDLE) dist/$(APP)-$(VERSION).zip
	@echo "Wrote dist/$(APP)-$(VERSION).zip"
	@shasum -a 256 dist/$(APP)-$(VERSION).zip
```
