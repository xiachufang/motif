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

# Which semver component `release-tag` bumps: patch | minor | major.
BUMP ?= patch

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
HOST_TAG ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(UNAME_M)
RELEASE_ARCH := $(UNAME_M)
ifeq ($(UNAME_M),aarch64)
RELEASE_ARCH := arm64
else ifeq ($(UNAME_M),amd64)
RELEASE_ARCH := x86_64
endif
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
MOTIFD_RELEASE_PACKAGE := motif-server
MOTIFD_RELEASE_BIN := motifd
MOTIFD_LINUX_TARGET := x86_64-unknown-linux-gnu
FLUTTER_WEB_BUILD := $(FLUTTER_DIR)/build/web

# Signed macOS release settings. Local builds use login-Keychain credentials;
# CI imports its five secret values into a temporary keychain. Temporary
# credentials and archives stay under MACOS_WORK_DIR and are always removed.
MACOS_ARCH ?= arm64
MACOS_WORK_DIR ?= $(if $(RUNNER_TEMP),$(RUNNER_TEMP)/motif-macos-release,$(RELEASE_DIR)/.macos-release)
MACOS_WORK_DIR := $(abspath $(MACOS_WORK_DIR))
MACOS_ARCHIVE_PATH ?= $(MACOS_WORK_DIR)/Motif.xcarchive
MACOS_APP_PATH ?= $(MACOS_ARCHIVE_PATH)/Products/Applications/Motif.app
MACOS_ENTITLEMENTS ?= $(FLUTTER_DIR)/macos/Runner/Release.entitlements
MACOS_RELEASE_LABEL ?= $(if $(filter tag,$(GITHUB_REF_TYPE)),$(GITHUB_REF_NAME),v$(VERSION))
MACOS_DMG ?= $(RELEASE_DIR)/Motif-$(MACOS_RELEASE_LABEL)-notarized.dmg
MACOS_SIGNING_KEYCHAIN ?= $(MACOS_WORK_DIR)/motif-signing.keychain-db
MACOS_SIGNING_IDENTITY_FILE ?= $(MACOS_WORK_DIR)/signing-identity
MACOS_KEYCHAIN_LIST_FILE ?= $(MACOS_WORK_DIR)/user-keychains
MACOS_NOTARY_KEYCHAIN_PROFILE ?= motif-notary

require_host = @[ "$(HOST_OS)" = "$(1)" ] || { echo "$@ must run on a $(1) host (current: $(HOST_OS))."; exit 1; }
macos_keychain_args = set --; if [ -f "$(MACOS_SIGNING_KEYCHAIN)" ]; then set -- --keychain "$(MACOS_SIGNING_KEYCHAIN)"; fi

.PHONY: help graph version check-tools check-cargo check-flutter check-zig \
	check-macos-tools check-ios-tools check-android-release-signing \
	check-ios-release-signing check-macos-release-credentials \
	check-macos-release-entitlements \
	deps deps-rust deps-flutter deps-web deps-android \
	deps-ios clean-flutter-ephemeral build-flutter-web release-flutter-web \
	release-macos release-linux release-windows \
	release-rust-macos release-rust-linux release-rust-windows \
	release-motifd-macos release-motifd-linux release-motifd-windows \
	release-flutter-macos release-flutter-linux \
	release-flutter-windows release-flutter-android release-flutter-ios \
	prepare-flutter-macos-release configure-flutter-macos-release \
	archive-flutter-macos-release import-macos-signing-certificate \
	sign-flutter-macos-release verify-flutter-macos-launch \
	package-flutter-macos-dmg \
	notarize-flutter-macos-dmg clean-macos-signing \
	release-manifest verify-release release-tag clean-release

help: ## Show available release targets.
	@printf "Motif release Makefile\n\n"
	@printf "Version: %s+%s\n" "$(VERSION)" "$(BUILD_NUMBER)"
	@printf "Output:  %s\n\n" "$(RELEASE_DIR)"
	@printf "Targets:\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_.-]+:.*##/ {printf "  %-28s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf "\nRun 'make graph' to print the target dependency graph.\n"

graph: ## Print the target dependency graph (ASCII).
	@printf "Dependency graph (ASCII):\n"
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
	@command -v security >/dev/null || { echo "Missing security."; exit 1; }
	@command -v openssl >/dev/null || { echo "Missing openssl."; exit 1; }
	@command -v file >/dev/null || { echo "Missing file."; exit 1; }
	@command -v uuidgen >/dev/null || { echo "Missing uuidgen."; exit 1; }
	@command -v ditto >/dev/null || { echo "Missing ditto."; exit 1; }
	@command -v hdiutil >/dev/null || { echo "Missing hdiutil."; exit 1; }
	@command -v xcrun >/dev/null || { echo "Missing xcrun."; exit 1; }
	@command -v spctl >/dev/null || { echo "Missing spctl."; exit 1; }

check-macos-release-credentials: ## Check Developer ID and Apple notarization credentials.
	@set -eu -o pipefail; \
	require_env() { \
		for name in "$$@"; do \
			if [ -z "$${!name:-}" ]; then echo "Missing required environment variable: $$name" >&2; exit 1; fi; \
		done; \
	}; \
	if [ -n "$${MACOS_DEVELOPER_ID_P12_BASE64:-}" ] || [ -n "$${MACOS_DEVELOPER_ID_P12_PASSWORD:-}" ]; then \
		require_env MACOS_DEVELOPER_ID_P12_BASE64 MACOS_DEVELOPER_ID_P12_PASSWORD; \
	elif ! security find-identity -v -p codesigning 2>/dev/null | grep -q 'Developer ID Application'; then \
		echo "Missing Developer ID identity: provide the MACOS_DEVELOPER_ID_P12_* variables or install it in Keychain." >&2; \
		exit 1; \
	fi; \
	if [ -n "$${APPLE_API_KEY_ID:-}" ] || [ -n "$${APPLE_API_ISSUER_ID:-}" ] || [ -n "$${APPLE_API_PRIVATE_KEY_BASE64:-}" ]; then \
		require_env APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_PRIVATE_KEY_BASE64; \
	elif ! xcrun notarytool history --keychain-profile "$(MACOS_NOTARY_KEYCHAIN_PROFILE)" >/dev/null 2>&1; then \
		echo "Missing notarytool Keychain profile '$(MACOS_NOTARY_KEYCHAIN_PROFILE)' and no APPLE_API_* credentials were provided." >&2; \
		exit 1; \
	fi

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

release-macos: release-rust-macos release-flutter-macos ## Build all macOS release artifacts.

release-linux: release-rust-linux release-flutter-linux ## Build all Linux release artifacts.

release-windows: release-rust-windows release-flutter-windows ## Build all Windows release artifacts.

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
	@ghostty_dll="$$(find target/release/build -type f -path '*/out/ghostty-install/bin/ghostty-vt.dll' -print -quit)"; \
		test -n "$$ghostty_dll"; \
		install -m 0755 "$$ghostty_dll" "$(RELEASE_DIR)/rust/windows-$(UNAME_M)/bin/ghostty-vt.dll"
	@tar -czf "$(RELEASE_DIR)/motif-rust-$(ARTIFACT_SUFFIX)-windows-$(UNAME_M).tar.gz" -C "$(RELEASE_DIR)/rust/windows-$(UNAME_M)" bin
	@echo "Rust binaries: $(RELEASE_DIR)/rust/windows-$(UNAME_M)/bin"

release-motifd-macos: check-cargo check-zig deps-rust build-flutter-web ## Build and archive the standalone motifd binary for macOS.
	$(call require_host,macos)
	@$(CARGO) build --release $(CARGO_LOCKED) -p $(MOTIFD_RELEASE_PACKAGE) --bin $(MOTIFD_RELEASE_BIN)
	@rm -rf "$(RELEASE_DIR)/motifd/macos-$(RELEASE_ARCH)"
	@mkdir -p "$(RELEASE_DIR)/motifd/macos-$(RELEASE_ARCH)"
	@install -m 0755 "target/release/$(MOTIFD_RELEASE_BIN)" "$(RELEASE_DIR)/motifd/macos-$(RELEASE_ARCH)/$(MOTIFD_RELEASE_BIN)"
	@tar -czf "$(RELEASE_DIR)/motifd-$(ARTIFACT_SUFFIX)-macos-$(RELEASE_ARCH).tar.gz" -C "$(RELEASE_DIR)/motifd/macos-$(RELEASE_ARCH)" "$(MOTIFD_RELEASE_BIN)"
	@echo "motifd binary: $(RELEASE_DIR)/motifd/macos-$(RELEASE_ARCH)/$(MOTIFD_RELEASE_BIN)"

release-motifd-linux: check-cargo check-zig deps-rust build-flutter-web ## Build and archive the standalone motifd binary for Linux.
	$(call require_host,linux)
	@rustup target add $(MOTIFD_LINUX_TARGET)
	@$(CARGO) build --release $(CARGO_LOCKED) --target $(MOTIFD_LINUX_TARGET) -p $(MOTIFD_RELEASE_PACKAGE) --bin $(MOTIFD_RELEASE_BIN)
	@rm -rf "$(RELEASE_DIR)/motifd/linux-x86_64"
	@mkdir -p "$(RELEASE_DIR)/motifd/linux-x86_64"
	@install -m 0755 "target/$(MOTIFD_LINUX_TARGET)/release/$(MOTIFD_RELEASE_BIN)" "$(RELEASE_DIR)/motifd/linux-x86_64/$(MOTIFD_RELEASE_BIN)"
	@tar -czf "$(RELEASE_DIR)/motifd-$(ARTIFACT_SUFFIX)-linux-x86_64.tar.gz" -C "$(RELEASE_DIR)/motifd/linux-x86_64" "$(MOTIFD_RELEASE_BIN)"
	@echo "motifd binary: $(RELEASE_DIR)/motifd/linux-x86_64/$(MOTIFD_RELEASE_BIN)"

release-motifd-windows: check-cargo check-zig deps-rust build-flutter-web ## Build and archive the standalone motifd binary for Windows.
	$(call require_host,windows)
	@$(CARGO) build --release $(CARGO_LOCKED) -p $(MOTIFD_RELEASE_PACKAGE) --bin $(MOTIFD_RELEASE_BIN)
	@rm -rf "$(RELEASE_DIR)/motifd/windows-$(RELEASE_ARCH)"
	@mkdir -p "$(RELEASE_DIR)/motifd/windows-$(RELEASE_ARCH)"
	@install -m 0755 "target/release/$(MOTIFD_RELEASE_BIN).exe" "$(RELEASE_DIR)/motifd/windows-$(RELEASE_ARCH)/$(MOTIFD_RELEASE_BIN).exe"
	@ghostty_dll="$$(find target/release/build -type f -path '*/out/ghostty-install/bin/ghostty-vt.dll' -print -quit)"; \
		test -n "$$ghostty_dll"; \
		install -m 0755 "$$ghostty_dll" "$(RELEASE_DIR)/motifd/windows-$(RELEASE_ARCH)/ghostty-vt.dll"
	@tar -czf "$(RELEASE_DIR)/motifd-$(ARTIFACT_SUFFIX)-windows-$(RELEASE_ARCH).tar.gz" -C "$(RELEASE_DIR)/motifd/windows-$(RELEASE_ARCH)" "$(MOTIFD_RELEASE_BIN).exe" ghostty-vt.dll
	@echo "motifd binary: $(RELEASE_DIR)/motifd/windows-$(RELEASE_ARCH)/$(MOTIFD_RELEASE_BIN).exe"

release-flutter-macos: check-macos-tools check-zig check-macos-release-credentials ## Build, Developer ID sign, notarize, and staple the Flutter macOS DMG.
	$(call require_host,macos)
	@set -eu -o pipefail; \
	cleanup() { make --no-print-directory clean-macos-signing; }; \
	trap cleanup EXIT; \
	cleanup; \
	rm -f "$(MACOS_DMG)"; \
	status=0; \
	make --no-print-directory notarize-flutter-macos-dmg || status=$$?; \
	if [ "$$status" -ne 0 ]; then rm -f "$(MACOS_DMG)"; fi; \
	exit "$$status"

# Prebuild native dependencies outside Xcode's sandbox. The subsequent archive
# build can then run without downloading Rust, Go, or Zig dependencies.
prepare-flutter-macos-release: deps-flutter
	@cd "$(FLUTTER_DIR)/ghostty" && zig build -Demit-lib-vt=true --fetch
	@cd "$(FLUTTER_DIR)" && bash scripts/build_motif_embed.sh --target macos-$(MACOS_ARCH)
	@cd "$(FLUTTER_DIR)" && bash scripts/build_tailscale.sh --target macos-$(MACOS_ARCH)

configure-flutter-macos-release: prepare-flutter-macos-release
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" build macos \
		-t lib/main_desktop.dart \
		--config-only \
		--release \
		--build-name "$(VERSION)" \
		--build-number "$(BUILD_NUMBER)" \
		--no-pub

# Archive without a distribution identity. Explicit bottom-up signing below
# prevents Xcode from silently selecting an Apple Development certificate.
archive-flutter-macos-release: configure-flutter-macos-release
	@rm -rf "$(MACOS_ARCHIVE_PATH)"
	@mkdir -p "$(MACOS_WORK_DIR)"
	@xcodebuild \
		-quiet \
		-project "$(FLUTTER_DIR)/macos/Runner.xcodeproj" \
		-scheme Runner \
		-configuration Release \
		-destination 'generic/platform=macOS' \
		-archivePath "$(MACOS_ARCHIVE_PATH)" \
		ARCHS="$(MACOS_ARCH)" \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_IDENTITY=- \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		DEVELOPMENT_TEAM= \
		archive
	@test -d "$(MACOS_APP_PATH)" || { echo "Archived app not found: $(MACOS_APP_PATH)" >&2; exit 1; }

import-macos-signing-certificate: archive-flutter-macos-release
	@set -eu -o pipefail; \
	if [ -n "$${MACOS_DEVELOPER_ID_P12_BASE64:-}" ]; then \
		certificate="$(MACOS_WORK_DIR)/developer-id.p12"; \
		password_file="$(MACOS_WORK_DIR)/keychain-password"; \
		printf '%s' "$$MACOS_DEVELOPER_ID_P12_BASE64" | openssl base64 -d -A -out "$$certificate"; \
		uuidgen > "$$password_file"; \
		keychain_password="$$(cat "$$password_file")"; \
		security create-keychain -p "$$keychain_password" "$(MACOS_SIGNING_KEYCHAIN)"; \
		security set-keychain-settings -lut 21600 "$(MACOS_SIGNING_KEYCHAIN)"; \
		security unlock-keychain -p "$$keychain_password" "$(MACOS_SIGNING_KEYCHAIN)"; \
		security list-keychains -d user > "$(MACOS_KEYCHAIN_LIST_FILE)"; \
		{ printf '"%s"\n' "$(MACOS_SIGNING_KEYCHAIN)"; cat "$(MACOS_KEYCHAIN_LIST_FILE)"; } \
			| xargs security list-keychains -d user -s; \
		security import "$$certificate" -k "$(MACOS_SIGNING_KEYCHAIN)" \
			-P "$$MACOS_DEVELOPER_ID_P12_PASSWORD" \
			-T /usr/bin/codesign -T /usr/bin/security; \
		security set-key-partition-list -S apple-tool:,apple: -s \
			-k "$$keychain_password" "$(MACOS_SIGNING_KEYCHAIN)"; \
		identity="$$(security find-identity -v -p codesigning "$(MACOS_SIGNING_KEYCHAIN)" \
			| awk '/Developer ID Application/ { print $$2; exit }')"; \
	else \
		identity="$$(security find-identity -v -p codesigning \
			| awk '/Developer ID Application/ { print $$2; exit }')"; \
	fi; \
	if [ -z "$$identity" ]; then \
		echo "No valid Developer ID Application identity was found." >&2; \
		exit 1; \
	fi; \
	printf '%s\n' "$$identity" > "$(MACOS_SIGNING_IDENTITY_FILE)"

sign-flutter-macos-release: import-macos-signing-certificate
	@set -eu -o pipefail; \
	identity="$$(cat "$(MACOS_SIGNING_IDENTITY_FILE)")"; \
	sign() { \
		target="$$1"; entitlements="$${2:-}"; \
		$(macos_keychain_args); \
		if [ -n "$$entitlements" ]; then set -- "$$@" --entitlements "$$entitlements"; fi; \
		codesign --force --sign "$$identity" "$$@" --options runtime --timestamp "$$target"; \
	}; \
	while IFS= read -r -d '' file_path; do \
		if file -b "$$file_path" | grep -q 'Mach-O'; then sign "$$file_path" || exit 1; fi; \
	done < <(find "$(MACOS_APP_PATH)/Contents" -type f ! -path '*/Contents/MacOS/*' -print0); \
	while IFS= read -r -d '' bundle; do sign "$$bundle" || exit 1; done \
		< <(find "$(MACOS_APP_PATH)/Contents" -depth -type d \
		\( -name '*.framework' -o -name '*.app' -o -name '*.appex' -o -name '*.xpc' \) -print0); \
	sign "$(MACOS_APP_PATH)" "$(MACOS_ENTITLEMENTS)"; \
	codesign --verify --deep --strict --verbose=2 "$(MACOS_APP_PATH)"; \
	codesign --display --verbose=4 "$(MACOS_APP_PATH)"

verify-flutter-macos-launch: sign-flutter-macos-release
	@set -eu -o pipefail; \
	executable="$(MACOS_APP_PATH)/Contents/MacOS/Motif"; \
	launch_log="$(MACOS_WORK_DIR)/launch-smoke-test.log"; \
	MOTIF_MACOS_RELEASE_PROBE=1 "$$executable" >"$$launch_log" 2>&1 & pid=$$!; \
	attempt=0; \
	while [ "$$attempt" -lt 80 ]; do \
		if ! kill -0 "$$pid" 2>/dev/null; then \
			status=0; wait "$$pid" || status=$$?; \
			if [ "$$status" -ne 0 ] || ! grep -q 'Motif macOS release probe passed.' "$$launch_log"; then \
				echo "Signed macOS app failed its Keychain launch probe (status $$status)." >&2; \
				sed -n '1,200p' "$$launch_log" >&2; \
				exit 1; \
			fi; \
			echo "Signed macOS app Keychain launch probe passed."; \
			exit 0; \
		fi; \
		attempt=$$((attempt + 1)); \
		sleep 0.25; \
	done; \
	kill "$$pid" 2>/dev/null || true; \
	wait "$$pid" 2>/dev/null || true; \
	echo "Signed macOS app Keychain launch probe timed out." >&2; \
	sed -n '1,200p' "$$launch_log" >&2; \
	exit 1

package-flutter-macos-dmg: verify-flutter-macos-launch
	@set -eu -o pipefail; \
	staging="$(MACOS_WORK_DIR)/dmg"; \
	identity="$$(cat "$(MACOS_SIGNING_IDENTITY_FILE)")"; \
	rm -rf "$$staging" "$(MACOS_DMG)"; \
	mkdir -p "$$staging" "$(RELEASE_DIR)"; \
	ditto "$(MACOS_APP_PATH)" "$$staging/Motif.app"; \
	ln -s /Applications "$$staging/Applications"; \
	hdiutil create -volname Motif -srcfolder "$$staging" -ov -format UDZO "$(MACOS_DMG)"; \
	$(macos_keychain_args); \
	codesign --force --sign "$$identity" "$$@" --timestamp "$(MACOS_DMG)"; \
	codesign --verify --strict --verbose=2 "$(MACOS_DMG)"

notarize-flutter-macos-dmg: package-flutter-macos-dmg
	@set -eu -o pipefail; \
	if [ -n "$${APPLE_API_PRIVATE_KEY_BASE64:-}" ]; then \
		api_key="$(MACOS_WORK_DIR)/AuthKey_$${APPLE_API_KEY_ID}.p8"; \
		printf '%s' "$$APPLE_API_PRIVATE_KEY_BASE64" | openssl base64 -d -A -out "$$api_key"; \
		chmod 600 "$$api_key"; \
		$(macos_keychain_args); \
		xcrun notarytool store-credentials "$(MACOS_NOTARY_KEYCHAIN_PROFILE)" \
			--key "$$api_key" --key-id "$$APPLE_API_KEY_ID" --issuer "$$APPLE_API_ISSUER_ID" "$$@"; \
	fi; \
	$(macos_keychain_args); \
	xcrun notarytool submit "$(MACOS_DMG)" --keychain-profile "$(MACOS_NOTARY_KEYCHAIN_PROFILE)" "$$@" --wait; \
	xcrun stapler staple "$(MACOS_DMG)"; \
	xcrun stapler validate "$(MACOS_DMG)"; \
	spctl --assess --type open --context context:primary-signature --verbose=2 "$(MACOS_DMG)"; \
	echo "Signed and notarized Flutter macOS DMG: $(MACOS_DMG)"

clean-macos-signing: ## Remove temporary macOS certificates, keychain, and archive.
	@if [ -f "$(MACOS_KEYCHAIN_LIST_FILE)" ]; then xargs security list-keychains -d user -s < "$(MACOS_KEYCHAIN_LIST_FILE)" || true; fi
	@if [ -f "$(MACOS_SIGNING_KEYCHAIN)" ]; then security delete-keychain "$(MACOS_SIGNING_KEYCHAIN)" || true; fi
	@rm -rf "$(MACOS_WORK_DIR)"

release-flutter-linux: deps-flutter ## Build and archive the Flutter Linux app on a Linux host.
	$(call require_host,linux)
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" build linux -t lib/main_desktop.dart --release --build-name "$(VERSION)" --build-number "$(BUILD_NUMBER)" --no-pub
	@bundle="$$(find "$(FLUTTER_DIR)/build/linux" -path '*/release/bundle' -type d -print -quit)"; \
		test -n "$$bundle" || { echo "Flutter Linux bundle not found."; exit 1; }; \
		rm -rf "$(RELEASE_DIR)/flutter/linux-$(UNAME_M)/Motif"; \
		mkdir -p "$(RELEASE_DIR)/flutter/linux-$(UNAME_M)/Motif"; \
		cp -R "$$bundle/." "$(RELEASE_DIR)/flutter/linux-$(UNAME_M)/Motif/"; \
		tar -czf "$(RELEASE_DIR)/Motif-flutter-$(ARTIFACT_SUFFIX)-linux-$(UNAME_M).tar.gz" -C "$(RELEASE_DIR)/flutter/linux-$(UNAME_M)" Motif
	@echo "Flutter Linux app: $(RELEASE_DIR)/flutter/linux-$(UNAME_M)/Motif"

release-flutter-windows: deps-flutter ## Build and archive the Flutter Windows app on a Windows host.
	$(call require_host,windows)
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" build windows -t lib/main_desktop.dart --release --build-name "$(VERSION)" --build-number "$(BUILD_NUMBER)" --no-pub
	@bundle="$$(find "$(FLUTTER_DIR)/build/windows" -path '*/runner/Release' -type d -print -quit)"; \
		test -n "$$bundle" || { echo "Flutter Windows bundle not found."; exit 1; }; \
		test -n "$$(find "$$bundle" -type f -name 'motif_embed.dll' -print -quit)" || { echo "motif_embed.dll missing from Flutter Windows bundle."; exit 1; }; \
		test -n "$$(find "$$bundle" -type f -name 'ghostty-vt.dll' -print -quit)" || { echo "ghostty-vt.dll missing from Flutter Windows bundle."; exit 1; }; \
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

check-macos-release-entitlements: ## Reject restricted entitlements unsupported by Developer ID distribution.
	@if grep -q '<key>keychain-access-groups</key>' "$(MACOS_ENTITLEMENTS)"; then \
		echo "$(MACOS_ENTITLEMENTS) contains keychain-access-groups, which requires an embedded provisioning profile and prevents this Developer ID app from launching." >&2; \
		exit 1; \
	fi

verify-release: deps-flutter check-cargo check-zig check-macos-release-entitlements ## Run release-focused checks.
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

release-tag: ## Bump pubspec (BUMP=patch|minor|major), commit, tag, and push to trigger the release CI.
	@case "$(BUMP)" in patch|minor|major) ;; \
		*) echo "release-tag: BUMP must be patch, minor or major (got '$(BUMP)')." >&2; exit 1;; esac; \
	if [ -n "$$(git status --porcelain)" ]; then \
		echo "release-tag: working tree is dirty; commit or stash changes first." >&2; exit 1; \
	fi; \
	IFS=. read -r major minor patch <<<"$(VERSION)"; \
	case "$(BUMP)" in \
		patch) patch=$$((patch + 1));; \
		minor) minor=$$((minor + 1)); patch=0;; \
		major) major=$$((major + 1)); minor=0; patch=0;; \
	esac; \
	new_ver="$$major.$$minor.$$patch"; new_build=$$(($(BUILD_NUMBER) + 1)); tag="v$$new_ver"; \
	if git rev-parse -q --verify "refs/tags/$$tag" >/dev/null; then \
		echo "release-tag: tag $$tag already exists. Pick a different BUMP or delete the tag." >&2; exit 1; \
	fi; \
	awk -v repl="version: $$new_ver+$$new_build" \
		'!done && /^version:/ {print repl; done=1; next} {print}' \
		"$(FLUTTER_DIR)/pubspec.yaml" > "$(FLUTTER_DIR)/pubspec.yaml.tmp"; \
	mv "$(FLUTTER_DIR)/pubspec.yaml.tmp" "$(FLUTTER_DIR)/pubspec.yaml"; \
	echo "Version: $(VERSION)+$(BUILD_NUMBER) -> $$new_ver+$$new_build ($(BUMP))"; \
	git add "$(FLUTTER_DIR)/pubspec.yaml"; \
	git commit -m "Release $$new_ver"; \
	git tag -a "$$tag" -m "Release $$new_ver+$$new_build"; \
	branch="$$(git rev-parse --abbrev-ref HEAD)"; \
	echo "Pushing $$branch and $$tag..."; \
	git push origin "$$branch"; \
	git push origin "$$tag"; \
	echo "Pushed $$tag — release CI triggered."

clean-release: ## Remove generated release artifacts under dist/release.
	@rm -rf "$(RELEASE_DIR)"
