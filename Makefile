# Makefile for Blocking Apps
# Usage:
#   make            - Debug build (.app only, unsigned)
#   make release    - Release build + sign + notarize + staple + .pkg + .dmg
#   make pkg        - Build signed installer .pkg from existing release .app
#   make dmg        - Build .dmg from existing release .app
#   make sign       - Sign the existing release .app
#   make notarize   - Notarize + staple the existing release .app
#   make github     - Create/update a GitHub pre-release from built artifacts
#   make clean      - Remove build artifacts
#
# Signing/notarization can be overridden on the command line, e.g.:
#   make release NOTARY_PROFILE=my-profile
# The notary profile is created once with:
#   xcrun notarytool store-credentials graham-notary-profile-blockingapps \
#       --apple-id <apple-id> --team-id C96ALZKYH6 --password <app-specific-pw>

SHELL      := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# --- Toolchain -------------------------------------------------------------
# xcodebuild needs a full Xcode, not the Command Line Tools. Resolve one and
# export it as DEVELOPER_DIR so we don't depend on `xcode-select` being set to
# Xcode system-wide. Override with `make DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer`.
ifndef DEVELOPER_DIR
DEVELOPER_DIR := $(shell \
	sel="$$(xcode-select -p 2>/dev/null)"; \
	if [ -x "$$sel/usr/bin/xcodebuild" ]; then echo "$$sel"; \
	elif [ -d /Applications/Xcode.app ]; then echo /Applications/Xcode.app/Contents/Developer; \
	elif [ -d /Applications/Xcode-beta.app ]; then echo /Applications/Xcode-beta.app/Contents/Developer; \
	fi)
endif
export DEVELOPER_DIR

_require_xcode:
	@if [ -z "$(DEVELOPER_DIR)" ] || [ ! -x "$(DEVELOPER_DIR)/usr/bin/xcodebuild" ]; then \
		echo "ERROR: no full Xcode found. Install Xcode, then either run" >&2; \
		echo "  sudo xcode-select -s /Applications/Xcode.app" >&2; \
		echo "or invoke: make DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer" >&2; \
		exit 1; \
	fi

APP_NAME   := Blocking Apps
APP_SLUG   := BlockingApps
BUNDLE_ID  := com.grahamrpugh.BlockingApps
PROJECT    := BlockingApps.xcodeproj
SCHEME     := Blocking Apps
VERSION    := $(shell grep 'MARKETING_VERSION = ' "$(PROJECT)/project.pbxproj" | head -1 | sed 's/.*= //;s/;//;s/ //g')
TAG        := v$(VERSION)

# --- Signing identities (Graham Pugh Developer ID, per plist-yaml-plist) ----
SIGN_ID_APP    ?= Developer ID Application: Graham Pugh
SIGN_ID_PKG    ?= Developer ID Installer: Graham Pugh
NOTARY_PROFILE ?= graham-notary-profile-blockingapps
TEAM_ID        ?= C96ALZKYH6

BUILD_DIR   := $(CURDIR)/.build
OUTPUT_DIR  := output
RELEASE_APP := $(BUILD_DIR)/Release/$(APP_NAME).app
DEBUG_APP   := $(BUILD_DIR)/Debug/$(APP_NAME).app
PKG_NAME    := $(APP_SLUG)-$(VERSION).pkg
PKG_PATH    := $(OUTPUT_DIR)/$(PKG_NAME)
COMPONENT   := $(OUTPUT_DIR)/$(APP_SLUG)-component.pkg
DMG_NAME    := $(APP_SLUG)-$(VERSION).dmg
DMG_PATH    := $(OUTPUT_DIR)/$(DMG_NAME)
DMG_STAGING := $(OUTPUT_DIR)/dmg-staging

.PHONY: all debug release pkg dmg sign notarize staple github clean clean-output \
        _require_xcode _sign_app _notarize_app _staple_app _pkg _dmg

all: debug

# --- Debug build -----------------------------------------------------------
debug: _require_xcode
	@echo "==> Using Xcode at $(DEVELOPER_DIR)"
	@echo "==> Building $(APP_NAME) (debug)…"
	@xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-destination "platform=macOS" \
		SYMROOT="$(BUILD_DIR)" \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY="$(SIGN_ID_APP)" \
		DEVELOPMENT_TEAM="$(TEAM_ID)" \
		OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
		build
	@echo "==> Debug app ready: $(DEBUG_APP)"
	@echo "==> Signed with stable identity so the Accessibility grant persists across rebuilds:"
	@codesign -d -r- "$(DEBUG_APP)" 2>&1 | sed -n 's/^designated => /    /p' || true

# --- Release build + full distribution pipeline ----------------------------
release: _require_xcode clean-output
	@echo "==> Using Xcode at $(DEVELOPER_DIR)"
	@echo "==> Building $(APP_NAME) $(VERSION) (release, universal)…"
	@xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
		-destination "platform=macOS" \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY="-" \
		DEVELOPMENT_TEAM="$(TEAM_ID)" \
		SYMROOT="$(BUILD_DIR)" \
		build
	@$(MAKE) --no-print-directory _sign_app
	@$(MAKE) --no-print-directory _notarize_app
	@$(MAKE) --no-print-directory _staple_app
	@$(MAKE) --no-print-directory _pkg
	@$(MAKE) --no-print-directory _dmg
	@echo "==> Release complete. Artifacts in $(OUTPUT_DIR)/"
	@open "$(OUTPUT_DIR)" || true

# --- Internal: sign the built app ------------------------------------------
_sign_app:
	@if [ ! -d "$(RELEASE_APP)" ]; then echo "ERROR: $(RELEASE_APP) not found." >&2; exit 1; fi
	@echo "==> Signing app bundle with '$(SIGN_ID_APP)'…"
	@/usr/bin/codesign --force --options runtime --timestamp \
		--sign "$(SIGN_ID_APP)" "$(RELEASE_APP)"
	@echo "==> Verifying code signature…"
	@/usr/bin/codesign --verify --deep --strict --verbose=2 "$(RELEASE_APP)"
	@/usr/bin/xcrun spctl --assess --type execute --verbose "$(RELEASE_APP)" || true

# --- Internal: notarize the signed app -------------------------------------
_notarize_app:
	@if [ ! -d "$(RELEASE_APP)" ]; then echo "ERROR: $(RELEASE_APP) not found." >&2; exit 1; fi
	@mkdir -p "$(OUTPUT_DIR)"
	@echo "==> Zipping app for notarization…"
	@/usr/bin/ditto -c -k --keepParent "$(RELEASE_APP)" "$(OUTPUT_DIR)/$(APP_SLUG).zip"
	@echo "==> Submitting to Apple notarization service…"
	@/usr/bin/xcrun notarytool submit "$(OUTPUT_DIR)/$(APP_SLUG).zip" \
		--keychain-profile "$(NOTARY_PROFILE)" --wait
	@rm -f "$(OUTPUT_DIR)/$(APP_SLUG).zip"

# --- Internal: staple the notarized app ------------------------------------
_staple_app:
	@echo "==> Stapling notarization ticket to app…"
	@/usr/bin/xcrun stapler staple -v "$(RELEASE_APP)"

# --- Sign / notarize / staple only -----------------------------------------
sign:     ; @$(MAKE) --no-print-directory _sign_app
notarize: ; @$(MAKE) --no-print-directory _notarize_app _staple_app
staple:   ; @$(MAKE) --no-print-directory _staple_app

# --- Build signed .pkg from existing release app ---------------------------
pkg:
	@if [ ! -d "$(RELEASE_APP)" ]; then echo "ERROR: run 'make release' first." >&2; exit 1; fi
	@$(MAKE) --no-print-directory _pkg
	@open "$(OUTPUT_DIR)" || true

_pkg:
	@mkdir -p "$(OUTPUT_DIR)"
	@echo "==> Verifying universal binary…"
	@lipo -info "$(RELEASE_APP)/Contents/MacOS/$(APP_NAME)"
	@echo "==> Creating component package…"
	@pkgbuild \
		--component "$(RELEASE_APP)" \
		--install-location /Applications \
		--identifier "$(BUNDLE_ID)" \
		--version "$(VERSION)" \
		--sign "$(SIGN_ID_PKG)" \
		"$(COMPONENT)"
	@echo "==> Writing distribution XML…"
	@( \
		echo '<?xml version="1.0" encoding="utf-8"?>'; \
		echo '<installer-gui-script minSpecVersion="2">'; \
		echo '	<title>$(APP_NAME)</title>'; \
		echo '	<pkg-ref id="$(BUNDLE_ID)"/>'; \
		echo '	<options customize="never" require-scripts="false" rootVolumeOnly="true" hostArchitectures="arm64,x86_64"/>'; \
		echo '	<choices-outline><line choice="default"><line choice="$(BUNDLE_ID)"/></line></choices-outline>'; \
		echo '	<choice id="default"/>'; \
		echo '	<choice id="$(BUNDLE_ID)" visible="false"><pkg-ref id="$(BUNDLE_ID)"/></choice>'; \
		echo '	<pkg-ref id="$(BUNDLE_ID)" version="$(VERSION)" onConclusion="none">$(notdir $(COMPONENT))</pkg-ref>'; \
		echo '</installer-gui-script>'; \
	) > "$(OUTPUT_DIR)/distribution.xml"
	@echo "==> Building distribution installer $(PKG_NAME)…"
	@productbuild \
		--distribution "$(OUTPUT_DIR)/distribution.xml" \
		--package-path "$(OUTPUT_DIR)" \
		--sign "$(SIGN_ID_PKG)" \
		"$(PKG_PATH)"
	@rm -f "$(COMPONENT)" "$(OUTPUT_DIR)/distribution.xml"
	@echo "==> Notarizing + stapling pkg…"
	@/usr/bin/xcrun notarytool submit "$(PKG_PATH)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	@/usr/bin/xcrun stapler staple -v "$(PKG_PATH)"
	@echo "==> Installer package ready: $(PKG_PATH)"

# --- Build .dmg from existing release app ----------------------------------
dmg:
	@if [ ! -d "$(RELEASE_APP)" ]; then echo "ERROR: run 'make release' first." >&2; exit 1; fi
	@$(MAKE) --no-print-directory _dmg
	@open "$(OUTPUT_DIR)" || true

_dmg:
	@mkdir -p "$(OUTPUT_DIR)"
	@rm -rf "$(DMG_STAGING)"
	@mkdir -p "$(DMG_STAGING)"
	@echo "==> Preparing DMG contents…"
	@cp -R "$(RELEASE_APP)" "$(DMG_STAGING)/$(APP_NAME).app"
	@ln -s /Applications "$(DMG_STAGING)/Applications"
	@echo "==> Creating disk image $(DMG_NAME)…"
	@hdiutil create \
		-volname "$(APP_NAME)" \
		-srcfolder "$(DMG_STAGING)" \
		-ov -format UDZO -imagekey zlib-level=9 \
		"$(DMG_PATH)"
	@rm -rf "$(DMG_STAGING)"
	@echo "==> Disk image ready: $(DMG_PATH)"

# --- Create / update GitHub pre-release ------------------------------------
github:
	@if [ ! -f "$(PKG_PATH)" ] && [ ! -f "$(DMG_PATH)" ]; then \
		echo "ERROR: no artifacts found — run 'make release' first." >&2; exit 1; fi
	@command -v gh >/dev/null || { echo "ERROR: gh not installed." >&2; exit 1; }
	@gh auth status >/dev/null 2>&1 || { echo "ERROR: run 'gh auth login'." >&2; exit 1; }
	@echo "==> Refreshing GitHub pre-release $(TAG)…"
	@gh release delete "$(TAG)" --cleanup-tag --yes >/dev/null 2>&1 || true
	@git tag -d "$(TAG)" >/dev/null 2>&1 || true
	@git tag "$(TAG)"
	@git push origin "$(TAG)"
	@gh release create "$(TAG)" \
		$(if $(wildcard $(PKG_PATH)),"$(PKG_PATH)#$(PKG_NAME)") \
		$(if $(wildcard $(DMG_PATH)),"$(DMG_PATH)#$(DMG_NAME)") \
		--title "$(APP_NAME) $(VERSION)" \
		--prerelease \
		--generate-notes
	@echo "==> GitHub pre-release $(TAG) created."

# --- Clean -----------------------------------------------------------------
clean:
	@echo "==> Cleaning build artifacts…"
	@rm -rf "$(BUILD_DIR)" "$(OUTPUT_DIR)"
	@echo "==> Clean complete."

clean-output:
	@rm -rf "$(OUTPUT_DIR)"
