APP     := LocalFlow
CONFIG  := release
BUILD   := .build/$(CONFIG)
BUNDLE  := dist/$(APP).app
CHECKAPP := dist/Check Model Updates.app
CONTENTS := $(BUNDLE)/Contents
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)

# Prefer a stable Apple Development identity so the code signature (and the
# TCC Accessibility grant tied to it) survives rebuilds; fall back to ad-hoc.
SIGN := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $$2; exit}')
ifeq ($(SIGN),)
SIGN := -
endif

.PHONY: build bundle run install zip bench bench-init check-updates check-updates-app clean

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
install: bundle
	-pkill -x $(APP)
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/$(APP).app
	@# LaunchServices needs a beat to register the replaced bundle; without
	@# this, `open` right after the copy fails with -600.
	@sleep 2
	@echo "Installed /Applications/$(APP).app — launch it from Spotlight or Launchpad."
	open /Applications/$(APP).app

# Zip the built .app for a GitHub Release. `ditto` preserves the bundle layout
# and code signature (plain `zip` can corrupt them). Consumed by the Homebrew
# cask — see docs/DISTRIBUTION.md.
zip: bundle
	ditto -c -k --keepParent $(BUNDLE) dist/$(APP)-$(VERSION).zip
	@echo "Wrote dist/$(APP)-$(VERSION).zip"
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
