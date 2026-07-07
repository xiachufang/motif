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
FLUTTER_MACOS_APP := $(FLUTTER_DIR)/build/macos/Build/Products/Release/Motif.app

require_host = @[ "$(HOST_OS)" = "$(1)" ] || { echo "$@ must run on a $(1) host (current: $(HOST_OS))."; exit 1; }

.PHONY: help graph version check-tools check-cargo check-flutter check-zig \
	check-macos-tools check-ios-tools check-android-release-signing \
	check-ios-release-signing deps deps-rust deps-flutter deps-web deps-android \
	deps-ios clean-flutter-ephemeral build-flutter-web release-flutter-web \
	release-macos release-linux release-windows \
	release-rust-macos release-rust-linux release-rust-windows \
	release-motifd-macos release-motifd-linux \
	release-flutter-macos release-flutter-linux \
	release-flutter-windows release-flutter-android release-flutter-ios \
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

release-flutter-macos: check-macos-tools deps-flutter ## Build and archive the Flutter macOS app.
	$(call require_host,macos)
	@cd "$(FLUTTER_DIR)" && "$(FLUTTER)" build macos -t lib/main_desktop.dart --release --build-name "$(VERSION)" --build-number "$(BUILD_NUMBER)" --no-pub
	@rm -rf "$(RELEASE_DIR)/macos/flutter"
	@mkdir -p "$(RELEASE_DIR)/macos/flutter"
	@cp -R "$(FLUTTER_MACOS_APP)" "$(RELEASE_DIR)/macos/flutter/Motif.app"
	@bash "$(FLUTTER_DIR)/scripts/strip_macos_x64.sh" "$(RELEASE_DIR)/macos/flutter/Motif.app" --resign --entitlements "$(FLUTTER_DIR)/macos/Runner/Release.entitlements"
	@cd "$(RELEASE_DIR)/macos/flutter" && ditto -c -k --keepParent Motif.app "../../Motif-flutter-macos-$(ARTIFACT_SUFFIX)-$(HOST_TAG).zip"
	@echo "Flutter macOS app: $(RELEASE_DIR)/macos/flutter/Motif.app"

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
