# Builds Stripe.app with only the Xcode Command Line Tools (no Xcode needed).
#
#   make            build build/Stripe.app for this Mac's architecture
#   make universal  build an arm64 + x86_64 app
#   make run        build, then (re)launch it
#   make install    copy to /Applications (replacing any existing copy)
#   make clean

APP_NAME    := Stripe
BUNDLE_ID   ?= com.ilfforever.stripe
MIN_MACOS   := 12.0
ARCHS       ?= $(shell uname -m)
# Sign with a stable local certificate when there is one (see
# build-support/make-signing-identity.sh), so Accessibility permission survives
# rebuilds; otherwise ad-hoc, which macOS treats as a new app every build.
SIGN_ID     ?= $(shell security find-certificate -c "Stripe Local Signing" >/dev/null 2>&1 && echo "Stripe Local Signing" || echo "-")

JOBS        ?= $(shell sysctl -n hw.ncpu)

BUILD       := build
APP         := $(BUILD)/$(APP_NAME).app
CONTENTS    := $(APP)/Contents
OBJ         := $(BUILD)/obj

SDK         := $(shell xcrun --show-sdk-path)
SRC         := MTMR
BRIDGE_HDR  := $(SRC)/CBridge/TouchBarPrivateApi-Bridging.h
SWIFT_SRCS  := $(shell find $(SRC) -name '*.swift')
C_SRCS      := $(wildcard $(SRC)/CBridge/*.m $(SRC)/CBridge/*.c)
ASSETS      := $(SRC)/Assets.xcassets
# Loaded by /usr/bin/perl rather than linked into the app (see NowPlaying.swift).
HELPER_SRC  := $(SRC)/NowPlayingHelper/NowPlayingHelper.m
HELPER      := $(BUILD)/NowPlayingHelper.dylib

FW_FLAGS    := -F build-support/Frameworks -F $(SDK)/System/Library/PrivateFrameworks
FRAMEWORKS  := -framework DFRFoundation -framework MultitouchSupport \
               -framework CoreBrightness -framework CoreDisplay \
               -framework Cocoa -framework SwiftUI -framework Carbon -framework IOKit -framework ServiceManagement

.PHONY: all universal run install clean FORCE
all: $(APP)

universal:
	$(MAKE) ARCHS="arm64 x86_64"

# One executable per arch, then lipo them together. Swift builds are incremental
# (only changed files and what depends on them are recompiled) and parallel.
$(BUILD)/$(APP_NAME): $(SWIFT_SRCS) $(C_SRCS) $(wildcard $(SRC)/CBridge/*.h) Makefile $(BUILD)/archs
	@mkdir -p $(OBJ)
	@for arch in $(ARCHS); do \
	  echo "==> compiling $$arch"; \
	  target=$$arch-apple-macos$(MIN_MACOS); \
	  mkdir -p $(OBJ)/$$arch; \
	  mkdir -p $(OBJ)/$$arch/swift; \
	  for f in $(C_SRCS); do \
	    o=$(OBJ)/$$arch/$$(basename $$f).o; \
	    [ "$$o" -nt "$$f" ] || clang -c -target $$target -isysroot $(SDK) -fobjc-arc -fmodules -O2 -w \
	      -I $(SRC)/CBridge $$f -o $$o || exit 1; \
	  done; \
	  srcs="$(abspath $(SWIFT_SRCS))"; \
	  build-support/output-file-map.sh $(abspath $(OBJ))/$$arch/swift $$srcs > $(OBJ)/$$arch/swift/map.json; \
	  swiftc -target $$target -sdk $(SDK) -O -swift-version 5 -incremental -j$(JOBS) \
	    -output-file-map $(OBJ)/$$arch/swift/map.json \
	    -module-name $(APP_NAME) -import-objc-header $(BRIDGE_HDR) -I $(SRC)/CBridge \
	    $(FW_FLAGS) $(FRAMEWORKS) \
	    $$srcs $(OBJ)/$$arch/*.o -o $(OBJ)/$$arch/$(APP_NAME) || exit 1; \
	done
	lipo -create $(foreach a,$(ARCHS),$(OBJ)/$(a)/$(APP_NAME)) -output $@

# Changes only when ARCHS does, so switching to or from `make universal` relinks.
$(BUILD)/archs: FORCE
	@mkdir -p $(BUILD)
	@echo "$(ARCHS)" | cmp -s - $@ || echo "$(ARCHS)" > $@
FORCE:

# Apple's perl may run as either architecture, so the helper is always universal.
$(HELPER): $(HELPER_SRC) Makefile
	@mkdir -p $(BUILD)
	clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=$(MIN_MACOS) -isysroot $(SDK) \
	    -fobjc-arc -O2 -framework Foundation $(HELPER_SRC) -o $@

$(APP): $(BUILD)/$(APP_NAME) $(HELPER) $(SRC)/Info.plist $(SRC)/MTMR.entitlements
	@rm -rf $(APP) && mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BUILD)/$(APP_NAME) $(CONTENTS)/MacOS/
	@# Info.plist: substitute the Xcode build-setting variables.
	sed -e 's/$$(EXECUTABLE_NAME)/$(APP_NAME)/g' -e 's/$$(PRODUCT_NAME)/$(APP_NAME)/g' \
	    -e 's/$$(PRODUCT_BUNDLE_IDENTIFIER)/$(BUNDLE_ID)/g' -e 's/$$(DEVELOPMENT_LANGUAGE)/en/g' \
	    -e 's/$$(MACOSX_DEPLOYMENT_TARGET)/$(MIN_MACOS)/g' $(SRC)/Info.plist > $(CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon' $(CONTENTS)/Info.plist
	@# Resources: loose copies of the asset catalog images (no actool), scripts, preset.
	@for set in $(ASSETS)/*.imageset; do \
	  name=$$(basename $$set .imageset); \
	  for f in $$set/*.png $$set/*.pdf; do if [ -f "$$f" ]; then cp "$$f" "$(CONTENTS)/Resources/$$name.$${f##*.}"; fi; done; \
	done
	@iconset=$(BUILD)/AppIcon.iconset; rm -rf $$iconset && mkdir -p $$iconset; \
	for s in 16 32 128 256 512; do \
	  cp $(ASSETS)/AppIcon.appiconset/logo-$$s.png $$iconset/icon_$${s}x$${s}.png; \
	  d=$$((s*2)); if [ -f $(ASSETS)/AppIcon.appiconset/logo-$$d.png ]; then cp $(ASSETS)/AppIcon.appiconset/logo-$$d.png $$iconset/icon_$${s}x$${s}@2x.png; fi; \
	done; iconutil -c icns $$iconset -o $(CONTENTS)/Resources/AppIcon.icns
	cp $(SRC)/defaultPreset.json $(CONTENTS)/Resources/
	cp -R $(SRC)/AppleScripts/ $(CONTENTS)/Resources/
	cp $(HELPER) $(CONTENTS)/Resources/
	codesign --force --sign "$(SIGN_ID)" $(CONTENTS)/Resources/NowPlayingHelper.dylib
	codesign --force --sign "$(SIGN_ID)" --entitlements $(SRC)/MTMR.entitlements $(APP)
	@echo "==> built $(APP)"

run: $(APP)
	-pkill -x $(APP_NAME); sleep 1
	open $(APP)

install: $(APP)
	-pkill -x $(APP_NAME); sleep 1
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP) /Applications/
	open /Applications/$(APP_NAME).app

clean:
	rm -rf $(BUILD)
