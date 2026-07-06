# Distributing LocalFlow

LocalFlow is an Apple-Silicon-only, on-device menu-bar app. This covers getting
it onto another Mac, and (optionally) publishing it via Homebrew.

## 1. Install on another Mac (build from source) — recommended

Simplest and least friction: a locally built app isn't quarantined, so there's
no Gatekeeper prompt and no signing to manage. Both machines must be **Apple
Silicon**.

```sh
xcode-select --install                            # once, if no build tools
git clone https://github.com/hjl1045/localflow    # private repo — that Mac needs GitHub access (gh auth login)
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

- **A public download URL.** Homebrew can't authenticate to a *private* repo's
  release assets. So the release `.zip` must be publicly downloadable — either
  make `hjl1045/localflow` public, or host the artifact in a public repo/release.
- **Notarization, for a clean install.** Without it, `brew install --cask`
  works but macOS Gatekeeper blocks first launch (quarantine). Notarizing needs
  a **paid Apple Developer account** ($99/yr): Developer ID signing →
  `xcrun notarytool submit --wait` → `xcrun stapler staple`. Without it, users
  must `xattr -dr com.apple.quarantine` once — fine for yourself, rough for a
  public cask.
- **Apple Silicon only** — the cask should declare `depends_on arch: :arm64`.

### Route A — your own tap (recommended for a personal app)

You control it end-to-end; users don't need your main repo.

1. **Build a release artifact** and attach it to a GitHub Release:
   ```sh
   make zip                       # -> dist/LocalFlow-<version>.zip (see Makefile target below)
   shasum -a 256 dist/LocalFlow-*.zip
   gh release create v0.1.0 dist/LocalFlow-0.1.0.zip --title "v0.1.0" --notes "…"
   ```
2. **Create a tap repo** named `homebrew-localflow` (the `homebrew-` prefix is
   required) under your account: `hjl1045/homebrew-localflow`.
3. Add `Casks/localflow.rb`:
   ```ruby
   cask "localflow" do
     version "0.1.0"
     sha256 "<sha256 of the zip>"

     url "https://github.com/hjl1045/localflow/releases/download/v#{version}/LocalFlow-#{version}.zip"
     name "LocalFlow"
     desc "Fully-local Wispr Flow-style dictation for Apple Silicon"
     homepage "https://github.com/hjl1045/localflow"

     depends_on arch: :arm64
     depends_on macos: ">= :sonoma"   # LSMinimumSystemVersion 14.0

     app "LocalFlow.app"

     zap trash: [
       "~/Library/Preferences/ai.xdlab.LocalFlow.plist",
     ]
   end
   ```
4. **Install from the tap:**
   ```sh
   brew tap hjl1045/localflow
   brew install --cask localflow          # or: brew install --cask hjl1045/localflow/localflow
   ```
   Bump `version` + `sha256` and cut a new release for each update.

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
