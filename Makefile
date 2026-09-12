APP     := LocalFlow
CONFIG  := release
BUILD   := .build/$(CONFIG)
# Build output directory. The `.noindex` SUFFIX is load-bearing, not decoration:
# every target leaves an .app in here carrying the SAME bundle id as the
# installed app (the `bundle` output, plus the `notarize` and `zip` staging
# copies). Indexed, macOS registers all of them — searching shows four
# LocalFlows, `open -b ai.xdlab.LocalFlow` can resolve to a build artifact, and
# because TCC keys grants to the code signature (and the notarize staging copy
# shares the installed copy's Developer ID identity) a Microphone/Accessibility
# grant can attach to a build artifact that the next `make clean` deletes.
#
# A `.metadata_never_index` marker inside the directory does NOT work — measured
# 2026-09-12: a bundle created under one was still indexed AND still appeared in
# `lsregister -dump`. Only the directory-name suffix suppressed both.
DIST    := dist.noindex
BUNDLE  := $(DIST)/$(APP).app
USERAPPS := $(HOME)/Applications

# Developer ID identity, used ONLY for notarized builds she installs herself.
# Empty until the certificate exists — the notarize target checks and explains.
DEVID := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $$2; exit}')
# Keychain profile created by `scripts/setup-notary.sh`.
NOTARY_PROFILE ?= localflow-notary
# Which keychain FILE holds that profile, passed explicitly on every notarytool
# call. Without it, `store-credentials` writes to the "Local Items" / iCloud
# keychain (its documented default), where the credential is invisible to
# `security find-generic-password` and vanished three times on 2026-09-08,
# 09-12 and again minutes later — twice mid-session, once blocking a release.
# A keychain file is inspectable and not subject to Local Items eviction.
NOTARY_KEYCHAIN ?= $(HOME)/Library/Keychains/login.keychain-db
ENTITLEMENTS := Support/LocalFlow.entitlements
NOTARIZED := $(DIST)/notarized/$(APP).app
CONTENTS := $(BUNDLE)/Contents
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)

# Prefer a stable Apple Development identity so the code signature (and the
# TCC Accessibility grant tied to it) survives rebuilds; fall back to ad-hoc.
SIGN := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $$2; exit}')
ifeq ($(SIGN),)
SIGN := -
endif

.PHONY: build bundle run install install-user uninstall-user notarize install-notarized install-notarized-user zip bench bench-init check-updates clean

build:
	swift build -c $(CONFIG)

$(DIST):
	@mkdir -p "$(DIST)"

# SwiftPM builds a bare executable; TCC permissions (mic, accessibility)
# require a real .app bundle with an Info.plist, so we assemble one.
bundle: build $(DIST)
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
install: bundle
	-pkill -x $(APP)
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/$(APP).app
	@# LaunchServices needs a beat to register the replaced bundle; without
	@# this, `open` right after the copy fails with -600.
	@sleep 2
	@echo "Installed /Applications/$(APP).app — in Spotlight and Launchpad."
	open /Applications/$(APP).app

# Sign with Developer ID + hardened runtime, notarize, and staple the ticket.
#
# A notarized app passes Gatekeeper anywhere, including a managed Mac that
# refuses un-notarized software, and a quarantined download that would otherwise
# be blocked on first launch. Used by BOTH the local install targets and `zip`
# since 2026-09-12 — public releases are notarized too. See docs/DISTRIBUTION.md.
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
	@xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" \
		--keychain "$(NOTARY_KEYCHAIN)" >/dev/null 2>&1 || { \
		echo "ERROR: no notary credentials stored as '$(NOTARY_PROFILE)'."; \
		echo "  Run: bash scripts/setup-notary.sh"; \
		exit 1; \
	}
	rm -rf $(DIST)/notarized && mkdir -p $(DIST)/notarized
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
	ditto -c -k --keepParent $(NOTARIZED) $(DIST)/notarize-upload.zip
	xcrun notarytool submit $(DIST)/notarize-upload.zip \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--keychain "$(NOTARY_KEYCHAIN)" --wait
	xcrun stapler staple $(NOTARIZED)
	@# The real test: Gatekeeper's own verdict on the stapled bundle.
	spctl -a -vvv -t install $(NOTARIZED)
	@rm -f $(DIST)/notarize-upload.zip
	@echo "Notarized and stapled: $(NOTARIZED)"

# Install the notarized build into /Applications — the normal path, mirroring
# `install` / `install-user`. Use install-notarized-user below only for a Mac
# that won't take /Applications.
#
# TCC note: grants are keyed to the code signature, so re-installing over a copy
# signed with the SAME Developer ID keeps Microphone and Accessibility. They are
# only voided when the identity changes (Apple Development → Developer ID, or a
# reissued certificate) — which is why this refuses to guess and just reports
# what the outgoing copy was signed with.
install-notarized: SIGN = $(DEVID)
install-notarized: notarize
	-pkill -x $(APP)
	@if [ -d "$(USERAPPS)/$(APP).app" ]; then \
		echo "WARNING: $(USERAPPS)/$(APP).app also exists."; \
		echo "         Two copies of the same bundle id make LaunchServices and TCC ambiguous."; \
		echo "         Remove it with:  make uninstall-user"; \
	fi
	@# Say whether the grants will survive, instead of always crying wolf.
	@if [ -d "/Applications/$(APP).app" ]; then \
		was=$$(codesign -dvvv "/Applications/$(APP).app" 2>&1 | awk -F= '/^Authority=/{print $$2; exit}'); \
		if [ "$$was" = "$(DEVID)" ]; then \
			echo "Replacing a copy signed with the same identity — Microphone/Accessibility grants carry over."; \
		else \
			echo "NOTE: the installed copy was signed '$$was', replacing it with '$(DEVID)'."; \
			echo "      The signature changes, so Microphone + Accessibility grants are VOID."; \
			echo "      Remove LocalFlow from both lists in System Settings > Privacy & Security"; \
			echo "      and re-add it (remove-then-re-add, not toggle)."; \
		fi; \
	fi
	rm -rf /Applications/$(APP).app
	cp -R $(NOTARIZED) /Applications/$(APP).app
	@# LaunchServices needs a beat to register the replaced bundle; without
	@# this, `open` right after the copy fails with -600.
	@sleep 2
	@echo "Installed notarized /Applications/$(APP).app."
	spctl -a -vv -t install /Applications/$(APP).app
	open /Applications/$(APP).app

# Same build, installed into ~/Applications instead — for a managed Mac where
# writing to /Applications needs admin rights or trips endpoint security.
# Install one or the other, never both: two copies of the same bundle id leave
# LaunchServices and TCC unable to tell which one a grant belongs to.
install-notarized-user: SIGN = $(DEVID)
install-notarized-user: notarize
	-pkill -x $(APP)
	@if [ -d "/Applications/$(APP).app" ]; then \
		echo "WARNING: /Applications/$(APP).app also exists."; \
		echo "         Two copies of the same bundle id make LaunchServices and TCC ambiguous —"; \
		echo "         and you can end up granting Microphone/Accessibility to the wrong one."; \
		echo "         Remove it BEFORE re-granting permissions:"; \
		echo "           rm -rf /Applications/$(APP).app"; \
	fi
	mkdir -p "$(USERAPPS)"
	rm -rf "$(USERAPPS)/$(APP).app"
	cp -R $(NOTARIZED) "$(USERAPPS)/$(APP).app"
	@sleep 2
	@echo "Installed notarized $(USERAPPS)/$(APP).app."
	@echo "If the signature changed, re-grant Microphone + Accessibility — the old grants are void."
	open "$(USERAPPS)/$(APP).app"

# Install into ~/Applications instead of /Applications — for a managed Mac
# where writing to the system-wide folder needs admin rights or trips endpoint
# security. It is the SAME bundle with the SAME signature: only the path
# differs, so Microphone and Accessibility behave identically. Nothing is
# written outside the home folder.
#
# Install ONE of these per machine. Two copies of the same bundle id confuse
# LaunchServices about which one a hotkey or a login item refers to.
install-user: bundle
	-pkill -x $(APP)
	@if [ -d "/Applications/$(APP).app" ]; then \
		echo "WARNING: /Applications/$(APP).app also exists. Two copies of the same"; \
		echo "         bundle id confuse LaunchServices and the TCC grants. Remove it:"; \
		echo "           rm -rf /Applications/$(APP).app"; \
	fi
	mkdir -p "$(USERAPPS)"
	rm -rf "$(USERAPPS)/$(APP).app"
	cp -R $(BUNDLE) "$(USERAPPS)/$(APP).app"
	@# LaunchServices needs a beat to register the bundle before `open` works.
	@sleep 2
	@echo "Installed $(USERAPPS)/$(APP).app — nothing was written to /Applications."
	open "$(USERAPPS)/$(APP).app"

# Remove the user-level install (leaves any /Applications copy alone).
uninstall-user:
	-pkill -x $(APP)
	rm -rf "$(USERAPPS)/$(APP).app"
	@echo "Removed $(APP) from $(USERAPPS)."

# Zip the NOTARIZED .app for a GitHub Release. `ditto` preserves the bundle
# layout, code signature and stapled ticket (plain `zip` can corrupt them).
# Consumed by the Homebrew cask — see docs/DISTRIBUTION.md.
#
# Public downloads were ad-hoc signed until 2026-09-12, to keep the developer's
# identity out of anything strangers could run `codesign -dvvv` on (THE-178).
# Her call reversed that once the certificate turned out to carry the ORG name,
# "The Autonomes Technologies LLC", rather than a personal one — so the trade is
# an organisation name in every download, in exchange for a build that opens by
# double-clicking: no quarantine dialog, no `xattr` incantation, and a Homebrew
# cask that works without one.
#
# This costs a notary round-trip per release, which is why it depends on
# `notarize` rather than `bundle`. The artifact IS the notarized bundle — do not
# re-sign it here, or the stapled ticket stops matching.
zip: SIGN = $(DEVID)
zip: notarize
	ditto -c -k --keepParent $(NOTARIZED) $(DIST)/$(APP)-$(VERSION).zip
	@# Assert the positive conditions on what actually gets published. Ad-hoc
	@# used to be asserted here for the opposite reason; the checks inverted with
	@# the decision, and they matter more now — an unstapled or wrongly signed
	@# artifact fails on the downloader's Mac, not on this one.
	@codesign -dvvv $(NOTARIZED) 2>&1 | grep -q "Authority=Developer ID Application" \
		|| { echo "ERROR: release build is not Developer ID signed — refusing to package"; exit 1; }
	@codesign -dvvv $(NOTARIZED) 2>&1 | grep -q "flags=.*runtime" \
		|| { echo "ERROR: release build lacks the hardened runtime — refusing to package"; exit 1; }
	@xcrun stapler validate $(NOTARIZED) >/dev/null 2>&1 \
		|| { echo "ERROR: release build has no stapled ticket — it would fail Gatekeeper offline"; exit 1; }
	@# Gatekeeper's verdict on the unzipped copy, as a downloader receives it.
	rm -rf $(DIST)/verify && mkdir -p $(DIST)/verify
	ditto -x -k $(DIST)/$(APP)-$(VERSION).zip $(DIST)/verify
	spctl -a -vv -t install "$(DIST)/verify/$(APP).app"
	@rm -rf $(DIST)/verify
	@echo "Wrote $(DIST)/$(APP)-$(VERSION).zip (Developer ID, notarized, stapled)"
	@shasum -a 256 $(DIST)/$(APP)-$(VERSION).zip
	@# Archive the debug symbols for THIS binary, matched by UUID. Without them
	@# a crash report from a downloader is a list of addresses: the release build
	@# is optimized, so the symbols live only in the .dSYM, and `swift build`
	@# overwrites it on the next build. Upload it alongside the zip on the
	@# GitHub Release — see docs/FEEDBACK.md for symbolicating with it.
	@# Verified needed 2026-09-09: the shipped v0.2.1 binary (UUID E154BA96…)
	@# had no surviving dSYM anywhere on the build machine.
	cp -R $(BUILD)/$(APP).dSYM $(DIST)/$(APP)-$(VERSION).dSYM
	ditto -c -k --keepParent $(DIST)/$(APP)-$(VERSION).dSYM $(DIST)/$(APP)-$(VERSION).dSYM.zip
	rm -rf $(DIST)/$(APP)-$(VERSION).dSYM
	@echo "Wrote $(DIST)/$(APP)-$(VERSION).dSYM.zip for these UUIDs:"
	@dwarfdump --uuid $(NOTARIZED)/Contents/MacOS/$(APP)

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
clean:
	rm -rf .build "$(DIST)"
