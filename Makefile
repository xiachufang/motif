SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:

# Flutter/Xcode build hooks touch shared ephemeral directories. Keep release
# orchestration serialized even when callers pass `make -j`.
.NOTPARALLEL:

CARGO ?= cargo
FLUTTER ?= flutter

FLUTTER_DIR := apps/flutter
RELEASE_DIR ?= dist/release
PUBSPEC_VERSION := $(shell awk '/^version:/ {print $$2; exit}' $(FLUTTER_DIR)/pubspec.yaml)
VERSION_PARTS := $(subst +, ,$(PUBSPEC_VERSION))
VERSION ?= $(word 1,$(VERSION_PARTS))
BUILD_NUMBER ?= $(word 2,$(VERSION_PARTS))
BUILD_NUMBER := $(if $(BUILD_NUMBER),$(BUILD_NUMBER),1)
ARTIFACT_SUFFIX ?= $(VERSION)-$(BUILD_NUMBER)

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
HOST_TAG ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(UNAME_M)
HOST_OS := unknown
HOST_EXE :=
ifeq ($(UNAME_S),Darwin)
HOST_OS := macos
else ifeq ($(UNAME_S),Linux)
HOST_OS := linux
else ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)))
HOST_OS := windows
HOST_EXE := .exe
endif

CARGO_LOCKED ?= --locked
FLUTTER_WEB_FLAGS ?= --no-wasm-dry-run
ANDROID_KEY_PROPERTIES ?= $(FLUTTER_DIR)/android/key.properties
ANDROID_ALLOW_DEBUG_SIGNING ?= 0
IOS_EXPORT_OPTIONS_PLIST ?=
IOS_ALLOW_DEVELOPMENT_APS ?= 0

RUST_RELEASE_PACKAGES := motif-server motif-cast motif-push-relay
RUST_RELEASE_BINS := motifd motif-cast motif-push-relay
FLUTTER_WEB_BUILD := $(FLUTTER_DIR)/build/web
MENUBAR_BIN := motif-menubar
MENUBAR_EXE := $(MENUBAR_BIN)$(HOST_EXE)
MENUBAR_BUNDLE_ID := io.allsunday.motif.menubar
MENUBAR_ICON := apps/menubar/icons/icon.png
MENUBAR_APP := target/release/bundle/Motif.app
FLUTTER_MACOS_APP := $(FLUTTER_DIR)/build/macos/Build/Products/Release/Motif.app

require_host = @[ "$(HOST_OS)" = "$(1)" ] || { echo "$@ must run on a $(1) host (current: $(HOST_OS))."; exit 1; }

.PHONY: help version check-tools check-cargo check-flutter check-zig \
	check-macos-tools check-ios-tools check-android-release-signing \
	check-ios-release-signing deps deps-rust deps-flutter deps-web deps-android \
	deps-ios clean-flutter-ephemeral build-flutter-web release-flutter-web \
	release-macos release-linux release-windows \
	release-rust-macos release-rust-linux release-rust-windows \
	release-menubar-macos release-menubar-linux release-menubar-windows \
	release-flutter-macos release-flutter-linux \
	release-flutter-windows release-flutter-android release-flutter-ios \
	release-manifest verify-release clean-release

help: ## Show available release targets.
	@printf "Motif release Makefile\n\n"
	@printf "Version: %s+%s\n" "$(VERSION)" "$(BUILD_NUMBER)"
	@printf "Output:  %s\n\n" "$(RELEASE_DIR)"
	@printf "Targets:\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_.-]+:.*##/ {printf "  %-28s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf "\nDependency graph (ASCII):\n"
	@awk '\
		function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$$/, "", s); return s } \
		function print_node(target, prefix, is_last, is_root,    i, dep, next_prefix, label) { \
			label = target; \
			if (seen[target]) label = label " (seen)"; \
			if (is_root) { \
				printf "%s\n", label; \
			} else { \
				printf "%s%s %s\n", prefix, (is_last ? "`--" : "|--"), label; \
			} \
			if (seen[target]++) return; \
			next_prefix = is_root ? "" : prefix (is_last ? "    " : "|   "); \
			for (i = 1; i <= dep_count[target]; i++) { \
				dep = dep_edge[target, i]; \
				print_node(dep, next_prefix, i == dep_count[target], 0); \
			} \
		} \
		/^[a-zA-Z0-9_.-]+:[^=]/ && /##/ { \
			target = $$1; \
			sub(/:.*/, "", target); \
			deps = $$0; \
			sub(/^[^:]+:[ \t]*/, "", deps); \
			sub(/[ \t]*##.*/, "", deps); \
			gsub(/[ \t]+/, " ", deps); \
			deps = trim(deps); \
			targets[++target_count] = target; \
			visible[target] = 1; \
			if (deps != "") { \
				n = split(deps, parts, " "); \
				for (i = 1; i <= n; i++) { \
					if (parts[i] == "") continue; \
					dep_edge[target, ++dep_count[target]] = parts[i]; \
					has_parent[parts[i]] = 1; \
				} \
			} \
		} \
		END { \
			for (i = 1; i <= target_count; i++) { \
				target = targets[i]; \
				if (!has_parent[target]) { \
					delete seen; \
					print_node(target, "", 1, 1); \
					print ""; \
				} \
			} \
		}' $(MAKEFILE_LIST)

version: ## Print the version read from apps/flutter/pubspec.yaml.
	@printf "%s+%s\n" "$(VERSION)" "$(BUILD_NUMBER)"

check-tools: check-cargo check-flutter ## Check the common local toolchain.

check-cargo: ## Check Cargo is available.
	@command -v "$(CARGO)" >/dev/null || { echo "Missing cargo. Install Rust first."; exit 1; }

check-flutter: ## Check Flutter is available.
	@command -v "$(FLUTTER)" >/dev/null || { echo "Missing flutter. Install Flutter first."; exit 1; }

check-zig: ## Check Zig 0.15.x for libghostty-vt builds.
	@command -v zig >/dev/null || { echo "Missing zig. motifd/libghostty-vt requires Zig 0.15.x."; exit 1; }
	@case "$$(zig version)" in 0.15.*) ;; *) echo "Zig $$(zig version) found, but libghostty-vt requires Zig 0.15.x."; exit 1 ;; esac

check-macos-tools: ## Check macOS app packaging tools.
	@[ "$(UNAME_S)" = "Darwin" ] || { echo "This target must run on macOS."; exit 1; }
	@command -v xcodebuild >/dev/null || { echo "Missing xcodebuild. Install Xcode command line tools."; exit 1; }
	@command -v codesign >/dev/null || { echo "Missing codesign."; exit 1; }
	@command -v ditto >/dev/null || { echo "Missing ditto."; exit 1; }
	@command -v sips >/dev/null || { echo "Missing sips."; exit 1; }
	@command -v iconutil >/dev/null || { echo "Missing iconutil."; exit 1; }

check-ios-tools: check-macos-tools ## Check iOS release build tools.
	@command -v pod >/dev/null || { echo "Missing CocoaPods. Run: brew install cocoapods"; exit 1; }

check-android-release-signing: ## Refuse non-publishable Android release signing.
	@if [ "$(ANDROID_ALLOW_DEBUG_SIGNING)" != "1" ] && grep -q 'signingConfigs.getByName("debug")' "$(FLUTTER_DIR)/android/app/build.gradle.kts"; then \
		echo "Android release currently uses debug signing in $(FLUTTER_DIR)/android/app/build.gradle.kts."; \
		echo "Configure upload-key signing before publishing, or set ANDROID_ALLOW_DEBUG_SIGNING=1 for a local non-publishable bundle."; \
		exit 1; \
	fi
	@if [ "$(ANDROID_ALLOW_DEBUG_SIGNING)" != "1" ] && [ ! -f "$(ANDROID_KEY_PROPERTIES)" ]; then \
		echo "Missing $(ANDROID_KEY_PROPERTIES). Add Android release signing before running release-flutter-android."; \
		exit 1; \
	fi

check-ios-release-signing: check-ios-tools ## Refuse non-publishable iOS push entitlement settings.
	@if [ "$(IOS_ALLOW_DEVELOPMENT_APS)" != "1" ] && /usr/libexec/PlistBuddy -c "Print :aps-environment" "$(FLUTTER_DIR)/ios/Runner/Runner.entitlements" 2>/dev/null | grep -qx "development"; then \
		echo "iOS Runner.entitlements uses aps-environment=development."; \
		echo "Switch it to production for App Store/TestFlight builds, or set IOS_ALLOW_DEVELOPMENT_APS=1 for a local build."; \
		exit 1; \
	fi

deps: deps-rust deps-flutter ## Fetch common Rust and Flutter dependencies.

deps-rust: check-cargo ## Fetch Rust dependencies using Cargo.lock.
	@$(CARGO) fetch $(CARGO_LOCKED)

clean-flutter-ephemeral: ## Remove stale Flutter iOS ephemeral package cache.
	@rm -rf "$(FLUTTER_DIR)/ios/Flutter/ephemeral/Packages/.packages"

deps-flutter: check-flutter clean-flutter-ephemeral ## Fetch Flutter dependencies.
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" pub get

deps-web: deps-flutter ## Fetch Flutter Web artifacts.
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" precache --web

deps-android: deps-flutter ## Fetch Android Flutter artifacts.
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" precache --android

deps-ios: check-ios-tools deps-flutter ## Fetch iOS Flutter/CocoaPods dependencies.
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" precache --ios
	@cd "$(FLUTTER_DIR)/ios" && pod install

build-flutter-web: deps-web ## Build Flutter Web for motifd embedding.
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" build web $(FLUTTER_WEB_FLAGS) --no-pub

release-flutter-web: build-flutter-web ## Copy and archive the standalone Flutter Web build.
	@rm -rf "$(RELEASE_DIR)/web"
	@mkdir -p "$(RELEASE_DIR)/web"
	@cp -R "$(FLUTTER_WEB_BUILD)/." "$(RELEASE_DIR)/web/"
	@tar -czf "$(RELEASE_DIR)/motif-web-$(ARTIFACT_SUFFIX).tar.gz" -C "$(RELEASE_DIR)" web
	@echo "Web build: $(RELEASE_DIR)/web"

release-macos: release-rust-macos release-menubar-macos release-flutter-macos ## Build all macOS release artifacts.

release-linux: release-rust-linux release-menubar-linux release-flutter-linux ## Build all Linux release artifacts.

release-windows: release-rust-windows release-menubar-windows release-flutter-windows ## Build all Windows release artifacts.

release-rust-macos: check-cargo check-zig deps-rust build-flutter-web ## Build Rust binaries for macOS.
	$(call require_host,macos)
	@$(CARGO) build --release $(CARGO_LOCKED) $(foreach pkg,$(RUST_RELEASE_PACKAGES),-p $(pkg))
	@rm -rf "$(RELEASE_DIR)/rust/macos-$(UNAME_M)"
	@mkdir -p "$(RELEASE_DIR)/rust/macos-$(UNAME_M)/bin"
	@$(foreach bin,$(RUST_RELEASE_BINS),install -m 0755 "target/release/$(bin)" "$(RELEASE_DIR)/rust/macos-$(UNAME_M)/bin/$(bin)";)
	@tar -czf "$(RELEASE_DIR)/motif-rust-$(ARTIFACT_SUFFIX)-macos-$(UNAME_M).tar.gz" -C "$(RELEASE_DIR)/rust/macos-$(UNAME_M)" bin
	@echo "Rust binaries: $(RELEASE_DIR)/rust/macos-$(UNAME_M)/bin"

release-rust-linux: check-cargo check-zig deps-rust build-flutter-web ## Build Rust binaries for Linux.
	$(call require_host,linux)
	@$(CARGO) build --release $(CARGO_LOCKED) $(foreach pkg,$(RUST_RELEASE_PACKAGES),-p $(pkg))
	@rm -rf "$(RELEASE_DIR)/rust/linux-$(UNAME_M)"
	@mkdir -p "$(RELEASE_DIR)/rust/linux-$(UNAME_M)/bin"
	@$(foreach bin,$(RUST_RELEASE_BINS),install -m 0755 "target/release/$(bin)" "$(RELEASE_DIR)/rust/linux-$(UNAME_M)/bin/$(bin)";)
	@tar -czf "$(RELEASE_DIR)/motif-rust-$(ARTIFACT_SUFFIX)-linux-$(UNAME_M).tar.gz" -C "$(RELEASE_DIR)/rust/linux-$(UNAME_M)" bin
	@echo "Rust binaries: $(RELEASE_DIR)/rust/linux-$(UNAME_M)/bin"

release-rust-windows: check-cargo check-zig deps-rust build-flutter-web ## Build Rust binaries for Windows.
	$(call require_host,windows)
	@$(CARGO) build --release $(CARGO_LOCKED) $(foreach pkg,$(RUST_RELEASE_PACKAGES),-p $(pkg))
	@rm -rf "$(RELEASE_DIR)/rust/windows-$(UNAME_M)"
	@mkdir -p "$(RELEASE_DIR)/rust/windows-$(UNAME_M)/bin"
	@$(foreach bin,$(RUST_RELEASE_BINS),install -m 0755 "target/release/$(bin).exe" "$(RELEASE_DIR)/rust/windows-$(UNAME_M)/bin/$(bin).exe";)
	@tar -czf "$(RELEASE_DIR)/motif-rust-$(ARTIFACT_SUFFIX)-windows-$(UNAME_M).tar.gz" -C "$(RELEASE_DIR)/rust/windows-$(UNAME_M)" bin
	@echo "Rust binaries: $(RELEASE_DIR)/rust/windows-$(UNAME_M)/bin"

release-menubar-macos: check-macos-tools check-cargo check-zig deps-rust build-flutter-web ## Build and archive the macOS menu-bar app.
	$(call require_host,macos)
	@$(CARGO) build --release $(CARGO_LOCKED) -p "$(MENUBAR_BIN)"
	@echo "==> assembling $(MENUBAR_APP)"
	@rm -rf "$(MENUBAR_APP)"
	@mkdir -p "$(MENUBAR_APP)/Contents/MacOS" "$(MENUBAR_APP)/Contents/Resources"
	@install -m 0755 "target/release/$(MENUBAR_BIN)" "$(MENUBAR_APP)/Contents/MacOS/$(MENUBAR_BIN)"
	@tmpdir="$$(mktemp -d)"; \
		iconset="$$tmpdir/icon.iconset"; \
		mkdir -p "$$iconset"; \
		for sz in 16 32 128 256 512; do \
			sips -z "$$sz" "$$sz" "$(MENUBAR_ICON)" --out "$$iconset/icon_$${sz}x$${sz}.png" >/dev/null; \
			sips -z "$$((sz * 2))" "$$((sz * 2))" "$(MENUBAR_ICON)" --out "$$iconset/icon_$${sz}x$${sz}@2x.png" >/dev/null; \
		done; \
		iconutil -c icns "$$iconset" -o "$(MENUBAR_APP)/Contents/Resources/icon.icns"; \
		rm -rf "$$tmpdir"
	@{ \
		printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'; \
		printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'; \
		printf '%s\n' '<plist version="1.0">'; \
		printf '%s\n' '<dict>'; \
		printf '%s\n' '  <key>CFBundleName</key><string>Motif</string>'; \
		printf '%s\n' '  <key>CFBundleDisplayName</key><string>Motif</string>'; \
		printf '%s\n' '  <key>CFBundleIdentifier</key><string>$(MENUBAR_BUNDLE_ID)</string>'; \
		printf '%s\n' '  <key>CFBundleExecutable</key><string>$(MENUBAR_BIN)</string>'; \
		printf '%s\n' '  <key>CFBundleIconFile</key><string>icon</string>'; \
		printf '%s\n' '  <key>CFBundlePackageType</key><string>APPL</string>'; \
		printf '%s\n' '  <key>CFBundleShortVersionString</key><string>$(VERSION)</string>'; \
		printf '%s\n' '  <key>CFBundleVersion</key><string>$(BUILD_NUMBER)</string>'; \
		printf '%s\n' '  <key>LSMinimumSystemVersion</key><string>11.0</string>'; \
		printf '%s\n' '  <key>LSUIElement</key><true/>'; \
		printf '%s\n' '  <key>NSHighResolutionCapable</key><true/>'; \
		printf '%s\n' '</dict>'; \
		printf '%s\n' '</plist>'; \
	} > "$(MENUBAR_APP)/Contents/Info.plist"
	@codesign --force --sign - "$(MENUBAR_APP)" >/dev/null 2>&1 || true
	@rm -rf "$(RELEASE_DIR)/macos/menubar"
	@mkdir -p "$(RELEASE_DIR)/macos/menubar"
	@cp -R "$(MENUBAR_APP)" "$(RELEASE_DIR)/macos/menubar/Motif.app"
	@cd "$(RELEASE_DIR)/macos/menubar" && ditto -c -k --keepParent Motif.app "../../Motif-menubar-$(ARTIFACT_SUFFIX)-$(HOST_TAG).zip"
	@echo "Menu-bar app: $(RELEASE_DIR)/macos/menubar/Motif.app"

release-menubar-linux: check-cargo check-zig deps-rust build-flutter-web ## Build and archive the Linux menu-bar app.
	$(call require_host,linux)
	@$(CARGO) build --release $(CARGO_LOCKED) -p "$(MENUBAR_BIN)"
	@rm -rf "$(RELEASE_DIR)/menubar/linux-$(UNAME_M)"
	@mkdir -p "$(RELEASE_DIR)/menubar/linux-$(UNAME_M)"
	@install -m 0755 "target/release/$(MENUBAR_BIN)" "$(RELEASE_DIR)/menubar/linux-$(UNAME_M)/$(MENUBAR_BIN)"
	@tar -czf "$(RELEASE_DIR)/Motif-menubar-$(ARTIFACT_SUFFIX)-linux-$(UNAME_M).tar.gz" -C "$(RELEASE_DIR)/menubar/linux-$(UNAME_M)" "$(MENUBAR_BIN)"
	@echo "Menu-bar app: $(RELEASE_DIR)/menubar/linux-$(UNAME_M)/$(MENUBAR_BIN)"

release-menubar-windows: check-cargo check-zig deps-rust build-flutter-web ## Build and archive the Windows menu-bar app.
	$(call require_host,windows)
	@$(CARGO) build --release $(CARGO_LOCKED) -p "$(MENUBAR_BIN)"
	@rm -rf "$(RELEASE_DIR)/menubar/windows-$(UNAME_M)"
	@mkdir -p "$(RELEASE_DIR)/menubar/windows-$(UNAME_M)"
	@install -m 0755 "target/release/$(MENUBAR_BIN).exe" "$(RELEASE_DIR)/menubar/windows-$(UNAME_M)/$(MENUBAR_BIN).exe"
	@tar -czf "$(RELEASE_DIR)/Motif-menubar-$(ARTIFACT_SUFFIX)-windows-$(UNAME_M).tar.gz" -C "$(RELEASE_DIR)/menubar/windows-$(UNAME_M)" "$(MENUBAR_BIN).exe"
	@echo "Menu-bar app: $(RELEASE_DIR)/menubar/windows-$(UNAME_M)/$(MENUBAR_BIN).exe"

release-flutter-macos: check-macos-tools deps-flutter ## Build and archive the Flutter macOS app.
	$(call require_host,macos)
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" build macos --release --build-name "$(VERSION)" --build-number "$(BUILD_NUMBER)" --no-pub
	@rm -rf "$(RELEASE_DIR)/macos/flutter"
	@mkdir -p "$(RELEASE_DIR)/macos/flutter"
	@cp -R "$(FLUTTER_MACOS_APP)" "$(RELEASE_DIR)/macos/flutter/Motif.app"
	@cd "$(RELEASE_DIR)/macos/flutter" && ditto -c -k --keepParent Motif.app "../../Motif-flutter-macos-$(ARTIFACT_SUFFIX)-$(HOST_TAG).zip"
	@echo "Flutter macOS app: $(RELEASE_DIR)/macos/flutter/Motif.app"

release-flutter-linux: deps-flutter ## Build and archive the Flutter Linux app on a Linux host.
	$(call require_host,linux)
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" build linux --release --build-name "$(VERSION)" --build-number "$(BUILD_NUMBER)" --no-pub
	@bundle="$$(find "$(FLUTTER_DIR)/build/linux" -path '*/release/bundle' -type d -print -quit)"; \
		test -n "$$bundle" || { echo "Flutter Linux bundle not found."; exit 1; }; \
		rm -rf "$(RELEASE_DIR)/flutter/linux-$(UNAME_M)/Motif"; \
		mkdir -p "$(RELEASE_DIR)/flutter/linux-$(UNAME_M)/Motif"; \
		cp -R "$$bundle/." "$(RELEASE_DIR)/flutter/linux-$(UNAME_M)/Motif/"; \
		tar -czf "$(RELEASE_DIR)/Motif-flutter-$(ARTIFACT_SUFFIX)-linux-$(UNAME_M).tar.gz" -C "$(RELEASE_DIR)/flutter/linux-$(UNAME_M)" Motif
	@echo "Flutter Linux app: $(RELEASE_DIR)/flutter/linux-$(UNAME_M)/Motif"

release-flutter-windows: deps-flutter ## Build and archive the Flutter Windows app on a Windows host.
	$(call require_host,windows)
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" build windows --release --build-name "$(VERSION)" --build-number "$(BUILD_NUMBER)" --no-pub
	@bundle="$$(find "$(FLUTTER_DIR)/build/windows" -path '*/runner/Release' -type d -print -quit)"; \
		test -n "$$bundle" || { echo "Flutter Windows bundle not found."; exit 1; }; \
		rm -rf "$(RELEASE_DIR)/flutter/windows-$(UNAME_M)/Motif"; \
		mkdir -p "$(RELEASE_DIR)/flutter/windows-$(UNAME_M)/Motif"; \
		cp -R "$$bundle/." "$(RELEASE_DIR)/flutter/windows-$(UNAME_M)/Motif/"; \
		tar -czf "$(RELEASE_DIR)/Motif-flutter-$(ARTIFACT_SUFFIX)-windows-$(UNAME_M).tar.gz" -C "$(RELEASE_DIR)/flutter/windows-$(UNAME_M)" Motif
	@echo "Flutter Windows app: $(RELEASE_DIR)/flutter/windows-$(UNAME_M)/Motif"

release-flutter-android: check-android-release-signing deps-android ## Build and copy the publishable Android App Bundle.
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" build appbundle --release --build-name "$(VERSION)" --build-number "$(BUILD_NUMBER)" --no-pub
	@mkdir -p "$(RELEASE_DIR)/android"
	@cp "$(FLUTTER_DIR)/build/app/outputs/bundle/release/app-release.aab" "$(RELEASE_DIR)/android/Motif-$(ARTIFACT_SUFFIX).aab"
	@echo "Android AAB: $(RELEASE_DIR)/android/Motif-$(ARTIFACT_SUFFIX).aab"

release-flutter-ios: check-ios-release-signing deps-ios ## Build and copy the signed iOS IPA.
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" build ipa --release --build-name "$(VERSION)" --build-number "$(BUILD_NUMBER)" --no-pub $(if $(IOS_EXPORT_OPTIONS_PLIST),--export-options-plist="$(IOS_EXPORT_OPTIONS_PLIST)")
	@ipa="$$(find "$(FLUTTER_DIR)/build/ios/ipa" -maxdepth 1 -name '*.ipa' -print -quit)"; \
		test -n "$$ipa" || { echo "iOS IPA not found in $(FLUTTER_DIR)/build/ios/ipa."; exit 1; }; \
		mkdir -p "$(RELEASE_DIR)/ios"; \
		cp "$$ipa" "$(RELEASE_DIR)/ios/Motif-$(ARTIFACT_SUFFIX).ipa"
	@echo "iOS IPA: $(RELEASE_DIR)/ios/Motif-$(ARTIFACT_SUFFIX).ipa"

verify-release: deps-flutter check-cargo check-zig ## Run release-focused checks.
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" analyze
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" test
	@$(CARGO) test $(CARGO_LOCKED) -p motif-server
	@$(CARGO) fmt --check -p motif-server

release-manifest: ## Write a manifest of generated release files.
	@mkdir -p "$(RELEASE_DIR)"
	@{ \
		echo "Motif release $(VERSION)+$(BUILD_NUMBER)"; \
		echo "Host: $(HOST_TAG)"; \
		echo "Generated: $$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
		echo; \
		find "$(RELEASE_DIR)" -type f | sort; \
	} > "$(RELEASE_DIR)/MANIFEST.txt"
	@echo "Manifest: $(RELEASE_DIR)/MANIFEST.txt"

clean-release: ## Remove generated release artifacts under dist/release.
	@rm -rf "$(RELEASE_DIR)"
