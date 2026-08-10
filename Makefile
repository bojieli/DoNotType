# Builds DoNotType.app from the SPM executable.
#
# There is no .xcodeproj on purpose: a pbxproj is unreviewable in a diff and merges badly, and
# everything it would provide here (bundle layout, plist, entitlements, signing) is a dozen lines
# of shell. Xcode can still open Package.swift directly for debugging.

CONFIG      ?= release
APP         := DoNotType
# The SPM product cannot also be called DoNotType -- the iOS project consumes this package and has
# a target by that name, and Xcode would resolve the collision by building the macOS executable
# for iOS. The binary is renamed back on the way into the bundle, which is what Info.plist's
# CFBundleExecutable expects.
PRODUCT     := DoNotTypeMac
BUNDLE_ID   := app.donottype
BUILD_DIR   := .build/$(CONFIG)
APP_BUNDLE  := .build/$(APP).app
CONTENTS    := $(APP_BUNDLE)/Contents

# Falls back to ad-hoc signing. Note that ad-hoc means macOS forgets your Accessibility grant on
# every rebuild, because TCC keys permissions to the code signature.
SIGN_ID     ?= $(shell security find-identity -v -p codesigning 2>/dev/null | \
                 grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
CODESIGN_ID := $(if $(SIGN_ID),$(SIGN_ID),-)

.PHONY: all build app run test eval clean install sign-info

all: app

build:
	swift build -c $(CONFIG)

test:
	swift test

eval:
	swift run -c $(CONFIG) dnt-eval suite eval/nearmiss

app: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BUILD_DIR)/$(PRODUCT)" "$(CONTENTS)/MacOS/$(APP)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@# The contract ships inside the bundle so the app does not depend on the source tree.
	@cp PROMPT.md "$(CONTENTS)/Resources/PROMPT.md"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@codesign --force --deep --options runtime \
		--entitlements Resources/$(APP).entitlements \
		--sign "$(CODESIGN_ID)" "$(APP_BUNDLE)" 2>/dev/null || \
		codesign --force --deep --sign - "$(APP_BUNDLE)"
	@echo "built $(APP_BUNDLE)  (signed with: $(CODESIGN_ID))"

run: app
	@pkill -x $(APP) 2>/dev/null || true
	@open "$(APP_BUNDLE)"

install: app
	@rm -rf "/Applications/$(APP).app"
	@cp -R "$(APP_BUNDLE)" /Applications/
	@echo "installed to /Applications/$(APP).app"

sign-info:
	@echo "identity: $(CODESIGN_ID)"
	@codesign -dv --entitlements - "$(APP_BUNDLE)" 2>&1 | head -20

clean:
	swift package clean
	@rm -rf "$(APP_BUNDLE)"
