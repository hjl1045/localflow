APP     := LocalFlow
CONFIG  := release
BUILD   := .build/$(CONFIG)
BUNDLE  := dist/$(APP).app
CHECKAPP := dist/Check Model Updates.app
USERAPPS := $(HOME)/Applications

# Developer ID identity, used ONLY for notarized builds she installs herself.
# Empty until the certificate exists — the notarize target checks and explains.
DEVID := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $$2; exit}')
# Keychain profile created by `scripts/setup-notary.sh`.
NOTARY_PROFILE ?= localflow-notary
ENTITLEMENTS := Support/LocalFlow.entitlements
NOTARIZED := dist/notarized/$(APP).app
CONTENTS := $(BUNDLE)/Contents
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)

# Prefer a stable Apple Development identity so the code signature (and the
# TCC Accessibility grant tied to it) survives rebuilds; fall back to ad-hoc.
SIGN := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $$2; exit}')
ifeq ($(SIGN),)
SIGN := -
endif

.PHONY: build bundle run install install-user uninstall-user notarize install-notarized zip bench bench-init check-updates check-updates-app clean

build:
	swift build -c $(CONFIG)

# SwiftPM builds a bare executable; TCC permissions (mic, accessibility)
# require a real .app bundle with an Info.plist, so we assemble one.
bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp Support/Info.plist $(CONTENTS)/Info.plist
	cp Support/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	cp $(BUILD)/$(APP) $(CONTENTS)/MacOS/$(APP)
	printf 'APPL????' > $(CONTENTS)/PkgInfo
	@# SPM resource bundles (KeyboardShortcuts localizations, etc.)
	@for b in $(BUILD)/*.bundle; do \
		[ -e "$$b" ] && cp -R "$$b" $(CONTENTS)/Resources/ || true; \
	done
	codesign --force --deep --sign "$(SIGN)" --identifier ai.xdlab.LocalFlow $(BUNDLE)
	@echo "Built $(BUNDLE)"

run: bundle
	open $(BUNDLE)

# Install into /Applications so Spotlight, Launchpad, and Finder can launch it
# like any app. Quit any running copy first so it can be replaced, then relaunch.
install: bundle check-updates-app
	-pkill -x $(APP)
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/$(APP).app
	@# The companion goes to /Applications too — built-but-not-installed means
	@# it may as well not exist (it sat unfound in dist/ once already).
	rm -rf "/Applications/Check Model Updates.app"
	cp -R "$(CHECKAPP)" "/Applications/Check Model Updates.app"
	@# LaunchServices needs a beat to register the replaced bundle; without
	@# this, `open` right after the copy fails with -600.
	@sleep 2
	@echo "Installed /Applications/$(APP).app and 'Check Model Updates.app' — both in Spotlight/Launchpad."
	open /Applications/$(APP).app

# Sign with Developer ID + hardened runtime, notarize, and staple the ticket.
#
# For builds SHE installs — a notarized app passes Gatekeeper anywhere, including
# a managed Mac that refuses un-notarized software. Deliberately NOT wired into
# `zip`: a Developer ID signature embeds the account identity in the binary, and
# what strangers download stays ad-hoc. See docs/DISTRIBUTION.md.
#
# One-time setup: create the certificate (Xcode > Settings > Accounts > Manage
# Certificates > + > Developer ID Application), then `bash scripts/setup-notary.sh`.
notarize: bundle
	@if [ -z "$(DEVID)" ]; then \
		echo "ERROR: no 'Developer ID Application' certificate in the keychain."; \
		echo "  Xcode > Settings > Accounts > (your team) > Manage Certificates > + >"; \
		echo "  'Developer ID Application'. An 'Apple Development' cert cannot notarize."; \
		exit 1; \
	fi
	@xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1 || { \
		echo "ERROR: no notary credentials stored as '$(NOTARY_PROFILE)'."; \
		echo "  Run: bash scripts/setup-notary.sh"; \
		exit 1; \
	}
	rm -rf dist/notarized && mkdir -p dist/notarized
	cp -R $(BUNDLE) $(NOTARIZED)
	@# Sign inside-out. `--deep` is unsupported for notarization — Apple rejects
	@# or silently mis-signs nested code — so nested bundles go first, app last.
	@find $(NOTARIZED)/Contents/Resources -name '*.bundle' -print -exec \
		codesign --force --options runtime --timestamp --sign "$(DEVID)" {} \;
	codesign --force --options runtime --timestamp \
		--entitlements $(ENTITLEMENTS) \
		--sign "$(DEVID)" --identifier ai.xdlab.LocalFlow $(NOTARIZED)
	@# Assert BEFORE spending a notary round-trip on a build that can't pass.
	@codesign -dvvv $(NOTARIZED) 2>&1 | grep -q "flags=.*runtime" \
		|| { echo "ERROR: hardened runtime missing — notarization would reject it"; exit 1; }
	codesign --verify --strict --verbose=2 $(NOTARIZED)
	ditto -c -k --keepParent $(NOTARIZED) dist/notarize-upload.zip
	xcrun notarytool submit dist/notarize-upload.zip \
		--keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(NOTARIZED)
	@# The real test: Gatekeeper's own verdict on the stapled bundle.
	spctl -a -vvv -t install $(NOTARIZED)
	@rm -f dist/notarize-upload.zip
	@echo "Notarized and stapled: $(NOTARIZED)"

# Install the notarized build into ~/Applications (the managed-Mac path).
#
# NOTE: this changes the code signature, so macOS treats it as a different app —
# the existing Microphone and Accessibility grants do NOT carry over. Remove
# LocalFlow from both lists in System Settings > Privacy & Security and re-add it.
# The companion rides along, so it must be signed with the SAME identity —
# otherwise you get a Developer ID LocalFlow next to an Apple Development
# companion, which is inconsistent and, on a Mac that demands notarized
# software, half-broken. Target-specific variables reach prerequisites, so this
# one assignment redirects check-updates-app's signing too.
install-notarized: SIGN = $(DEVID)
install-notarized: notarize check-updates-app
	-pkill -x $(APP)
	@if [ -d "/Applications/$(APP).app" ]; then \
		echo "WARNING: /Applications/$(APP).app also exists, signed with a DIFFERENT identity."; \
		echo "         Two copies of the same bundle id make LaunchServices and TCC ambiguous —"; \
		echo "         and you can end up granting Microphone/Accessibility to the wrong one."; \
		echo "         Remove it BEFORE re-granting permissions:"; \
		echo "           rm -rf /Applications/$(APP).app '/Applications/Check Model Updates.app'"; \
	fi
	mkdir -p "$(USERAPPS)"
	rm -rf "$(USERAPPS)/$(APP).app"
	cp -R $(NOTARIZED) "$(USERAPPS)/$(APP).app"
	@sleep 2
	@echo "Installed notarized $(USERAPPS)/$(APP).app"
	@echo "Re-grant Microphone + Accessibility: the signature changed, so the old grants are void."
	open "$(USERAPPS)/$(APP).app"

# Install into ~/Applications instead of /Applications — for a managed Mac
# where writing to the system-wide folder needs admin rights or trips endpoint
# security. It is the SAME bundle with the SAME signature: only the path
# differs, so Microphone and Accessibility behave identically. Nothing is
# written outside the home folder.
#
# Install ONE of these per machine. Two copies of the same bundle id confuse
# LaunchServices about which one a hotkey or a login item refers to.
install-user: bundle check-updates-app
	-pkill -x $(APP)
	@if [ -d "/Applications/$(APP).app" ]; then \
		echo "WARNING: /Applications/$(APP).app also exists. Two copies of the same"; \
		echo "         bundle id confuse LaunchServices and the TCC grants. Remove it:"; \
		echo "           rm -rf /Applications/$(APP).app '/Applications/Check Model Updates.app'"; \
	fi
	mkdir -p "$(USERAPPS)"
	rm -rf "$(USERAPPS)/$(APP).app"
	cp -R $(BUNDLE) "$(USERAPPS)/$(APP).app"
	rm -rf "$(USERAPPS)/Check Model Updates.app"
	cp -R "$(CHECKAPP)" "$(USERAPPS)/Check Model Updates.app"
	@# LaunchServices needs a beat to register the bundle before `open` works.
	@sleep 2
	@echo "Installed $(USERAPPS)/$(APP).app — nothing was written to /Applications."
	open "$(USERAPPS)/$(APP).app"

# Remove the user-level install (leaves any /Applications copy alone).
uninstall-user:
	-pkill -x $(APP)
	rm -rf "$(USERAPPS)/$(APP).app" "$(USERAPPS)/Check Model Updates.app"
	@echo "Removed $(APP) from $(USERAPPS)."

# Zip the built .app for a GitHub Release. `ditto` preserves the bundle layout
# and code signature (plain `zip` can corrupt them). Consumed by the Homebrew
# cask — see docs/DISTRIBUTION.md.
#
# The published artifact is re-signed AD-HOC in a staging copy, deliberately: an
# Apple Development signature embeds the developer's email and Team ID, which
# `codesign -dvvv` prints for anyone who downloads it. Local builds keep the
# real identity (it's what keeps the TCC Accessibility grant stable across
# rebuilds); only the thing strangers download is stripped.
zip: bundle
	rm -rf dist/release && mkdir -p dist/release
	cp -R $(BUNDLE) dist/release/$(APP).app
	codesign --force --deep --sign - --identifier ai.xdlab.LocalFlow dist/release/$(APP).app
	@# Assert the positive condition — the artifact must be ad-hoc with no team.
	@codesign -dvvv dist/release/$(APP).app 2>&1 | grep -q "Signature=adhoc" \
		|| { echo "ERROR: release build is not ad-hoc signed — refusing to package"; exit 1; }
	@codesign -dvvv dist/release/$(APP).app 2>&1 | grep -q "TeamIdentifier=not set" \
		|| { echo "ERROR: release build carries a TeamIdentifier — refusing to package"; exit 1; }
	ditto -c -k --keepParent dist/release/$(APP).app dist/$(APP)-$(VERSION).zip
	@echo "Wrote dist/$(APP)-$(VERSION).zip (ad-hoc signed, no embedded identity)"
	@shasum -a 256 dist/$(APP)-$(VERSION).zip

# Which model is actually worth running: error rate vs latency vs RAM, measured
# on this machine with bench/samples/. `bench-init` synthesizes a starter set;
# replace it with recordings of your own voice for numbers you can trust.
bench-init:
	python3 scripts/bench.py --generate

bench: bundle
	python3 scripts/bench.py --json reports/bench-$(shell date +%Y-%m-%d).json

# Is anything upstream newer than what we pin/run? Deps, WhisperKit CoreML
# models, Ollama + its model weights. Run monthly; re-run `make bench` only when
# this reports something new. See docs/MODEL-UPDATES.md.
check-updates:
	python3 scripts/check-updates.py

# The same check as a double-clickable app (Dock/Spotlight), for running it by
# hand instead of on a schedule. The launcher shells back to this repo, so
# re-run this target if the repo ever moves.
check-updates-app: Support/CheckUpdatesIcon.icns
	rm -rf "$(CHECKAPP)"
	mkdir -p "$(CHECKAPP)/Contents/MacOS" "$(CHECKAPP)/Contents/Resources"
	sed 's|@REPO@|$(CURDIR)|' Support/check-updates-launcher.sh > "$(CHECKAPP)/Contents/MacOS/CheckModelUpdates"
	chmod +x "$(CHECKAPP)/Contents/MacOS/CheckModelUpdates" scripts/check-updates-run.command
	cp Support/CheckUpdates-Info.plist "$(CHECKAPP)/Contents/Info.plist"
	cp Support/CheckUpdatesIcon.icns "$(CHECKAPP)/Contents/Resources/CheckUpdatesIcon.icns"
	printf 'APPL????' > "$(CHECKAPP)/Contents/PkgInfo"
	codesign --force --sign "$(SIGN)" --identifier ai.xdlab.LocalFlow.CheckUpdates "$(CHECKAPP)"
	@echo "Built $(CHECKAPP) — drag it to the Dock, or run: open '$(CHECKAPP)'"

# Regenerated from an SF Symbol; committed so a normal build never needs Swift
# to render an icon. Refresh ring = the check cycle, same family background as
# the mic so the two read as siblings but not twins at Dock size.
Support/CheckUpdatesIcon.icns:
	./Support/make-icon.sh CheckUpdatesIcon arrow.triangle.2.circlepath

clean:
	rm -rf .build dist
