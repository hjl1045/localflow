APP     := LocalFlow
CONFIG  := release
BUILD   := .build/$(CONFIG)
BUNDLE  := dist/$(APP).app
CONTENTS := $(BUNDLE)/Contents

# Prefer a stable Apple Development identity so the code signature (and the
# TCC Accessibility grant tied to it) survives rebuilds; fall back to ad-hoc.
SIGN := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $$2; exit}')
ifeq ($(SIGN),)
SIGN := -
endif

.PHONY: build bundle run clean

build:
	swift build -c $(CONFIG)

# SwiftPM builds a bare executable; TCC permissions (mic, accessibility)
# require a real .app bundle with an Info.plist, so we assemble one.
bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp Support/Info.plist $(CONTENTS)/Info.plist
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

clean:
	rm -rf .build dist
