# ─────────────────────────────────────────────────────────────────────────────
# Gate — developer entry points.
#
#   make            same as `make help`
#   make project    regenerate Gate.xcodeproj from project.yml, then verify it
#   make verify     assert the traps in docs/06-build-plan.md step 1.6 are clear
#   make test       run the Kernel unit tests (SwiftPM, no Xcode, no device)
#   make lint       SwiftLint + plutil -lint on every Config/ plist
#   make clean      delete the generated project and all build products
#
# Every target checks that its tool exists first and tells you how to install it.
# `verify` is the exception: it is pure grep and runs anywhere, including Linux
# CI, and it is the only automated defence against the two silent, expensive
# misconfigurations on this stack — a wrong NSExtensionPointIdentifier (the
# extension is never launched and there is no runtime signal at all) and
# GateReport embedded as a plain app-extension (a full App Store review cycle
# to find out).
# ─────────────────────────────────────────────────────────────────────────────

SHELL := /bin/bash
.DEFAULT_GOAL := help

PROJECT       := Gate
XCODEPROJ     := $(PROJECT).xcodeproj
PBXPROJ       := $(XCODEPROJ)/project.pbxproj
SPEC          := project.yml
TESTS_DIR     := Tests
CONFIG_DIR    := Config

XCODEGEN      ?= xcodegen
SWIFT         ?= swift
SWIFTLINT     ?= swiftlint
PLUTIL        ?= plutil

# Kept in lockstep with APP_GROUP / BUNDLE_ID_PREFIX in Config/Build.xcconfig.
# `make verify` fails if they ever drift apart.
APP_GROUP     := group.com.turnonac.gate
BUNDLE_PREFIX := com.turnonac.gate

.PHONY: help project verify verify-config verify-project test lint clean

# ─────────────────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "Gate — make targets"
	@echo ""
	@echo "  project   Regenerate $(XCODEPROJ) from $(SPEC), then run verify."
	@echo "            needs xcodegen   (brew install xcodegen)"
	@echo "  verify    Check extension point identifiers, entitlements, the App"
	@echo "            Group, and the GateReport product type + embed phase."
	@echo "            needs nothing    (pure grep; safe on Linux CI)"
	@echo "  test      swift test in $(TESTS_DIR)/ — the Kernel unit tests."
	@echo "            needs swift      (Xcode, or a swift.org toolchain)"
	@echo "  lint      swiftlint, plus plutil -lint on $(CONFIG_DIR)/ plists."
	@echo "            needs swiftlint  (brew install swiftlint)"
	@echo "  clean     Remove $(XCODEPROJ), DerivedData/ and every .build/ dir."
	@echo ""
	@echo "First run on a new machine:"
	@echo "    cp $(CONFIG_DIR)/Local.xcconfig.example $(CONFIG_DIR)/Local.xcconfig"
	@echo "    \$$EDITOR $(CONFIG_DIR)/Local.xcconfig   # put your Team ID in it"
	@echo "    make project"
	@echo ""

# ─────────────────────────────────────────────────────────────────────────────
# project — docs/06-build-plan.md steps 1.2 and 1.6
# ─────────────────────────────────────────────────────────────────────────────
project:
	@command -v $(XCODEGEN) >/dev/null 2>&1 || { \
	  echo ""; \
	  echo "ERROR: '$(XCODEGEN)' not found on PATH."; \
	  echo ""; \
	  echo "  XcodeGen generates $(XCODEPROJ) from $(SPEC). The project file is"; \
	  echo "  git-ignored on purpose and is never hand-edited."; \
	  echo ""; \
	  echo "  Install:  brew install xcodegen"; \
	  echo "  Source:   https://github.com/yonaskolb/XcodeGen"; \
	  echo ""; \
	  exit 1; }
	@test -f $(SPEC) || { echo "ERROR: $(SPEC) not found — run make from the repo root."; exit 1; }
	@test -f $(CONFIG_DIR)/Local.xcconfig || { \
	  echo ""; \
	  echo "NOTE: $(CONFIG_DIR)/Local.xcconfig is missing, so TEAM_ID is empty."; \
	  echo "      The project will generate, but signing fails in Xcode until you run:"; \
	  echo "          cp $(CONFIG_DIR)/Local.xcconfig.example $(CONFIG_DIR)/Local.xcconfig"; \
	  echo ""; }
	$(XCODEGEN) generate --spec $(SPEC)
	@$(MAKE) --no-print-directory verify

# ─────────────────────────────────────────────────────────────────────────────
# verify
# ─────────────────────────────────────────────────────────────────────────────
verify: verify-config verify-project
	@echo ""
	@echo "==> verify: all checks passed."
	@echo ""

verify-config:
	@echo "==> Verifying $(CONFIG_DIR)/ — extension points, entitlements, App Group"
	@fail=0; \
	want() { \
	  if grep -qF -- "$$2" "$$1"; then \
	    printf '    ok    %-32s %s\n' "$$(basename $$1)" "$$2"; \
	  else \
	    printf '    FAIL  %-32s expected: %s\n' "$$(basename $$1)" "$$2"; fail=1; \
	  fi; \
	}; \
	reject() { \
	  if grep -qF -- "$$2" "$$1"; then \
	    printf '    FAIL  %-32s must NOT contain: %s\n' "$$(basename $$1)" "$$2"; fail=1; \
	  else \
	    printf '    ok    %-32s absent: %s\n' "$$(basename $$1)" "$$2"; \
	  fi; \
	}; \
	want   $(CONFIG_DIR)/ActivityMonitor-Info.plist     'com.apple.deviceactivity.monitor-extension'; \
	want   $(CONFIG_DIR)/ShieldConfiguration-Info.plist 'com.apple.ManagedSettingsUI.shield-configuration-service'; \
	want   $(CONFIG_DIR)/ShieldAction-Info.plist        'com.apple.ManagedSettings.shield-action-service'; \
	want   $(CONFIG_DIR)/Report-Info.plist              'com.apple.deviceactivityui.report-extension'; \
	reject $(CONFIG_DIR)/ShieldAction-Info.plist        'ManagedSettingsUI.shield-action-service'; \
	want   $(CONFIG_DIR)/Report-Info.plist              'EXAppExtensionAttributes'; \
	reject $(CONFIG_DIR)/Report-Info.plist              'NSExtensionPrincipalClass'; \
	reject $(CONFIG_DIR)/Report-Info.plist              '<key>NSExtension</key>'; \
	want   $(CONFIG_DIR)/Gate-App.entitlements         'com.apple.developer.family-controls'; \
	want   $(CONFIG_DIR)/Gate-Extension.entitlements   'com.apple.developer.family-controls'; \
	want   $(CONFIG_DIR)/Gate-App.entitlements         '$(APP_GROUP)'; \
	want   $(CONFIG_DIR)/Gate-Extension.entitlements   '$(APP_GROUP)'; \
	want   $(CONFIG_DIR)/Gate-App.entitlements         'keychain-access-groups'; \
	reject $(CONFIG_DIR)/Gate-Extension.entitlements   'keychain-access-groups'; \
	reject $(CONFIG_DIR)/Gate-App.entitlements         'com.apple.developer.deviceactivity'; \
	reject $(CONFIG_DIR)/Gate-Extension.entitlements   'com.apple.developer.deviceactivity'; \
	reject $(CONFIG_DIR)/Gate-App.entitlements         'app-and-website-usage'; \
	reject $(CONFIG_DIR)/Gate-Extension.entitlements   'app-and-website-usage'; \
	want   $(CONFIG_DIR)/Build.xcconfig                'APP_GROUP = $(APP_GROUP)'; \
	want   $(CONFIG_DIR)/Build.xcconfig                'BUNDLE_ID_PREFIX = $(BUNDLE_PREFIX)'; \
	want   $(CONFIG_DIR)/Build.xcconfig                'IPHONEOS_DEPLOYMENT_TARGET = 17.0'; \
	want   $(CONFIG_DIR)/Build.xcconfig                'SWIFT_VERSION = 6.0'; \
	want   $(CONFIG_DIR)/Build.xcconfig                'SWIFT_STRICT_CONCURRENCY = complete'; \
	if [ $$fail -ne 0 ]; then \
	  echo ""; \
	  echo "    The exact strings are in docs/02-api-reference.md, sections 2 and 3."; \
	  echo "    A monitor identifier missing its '-extension' suffix builds, installs,"; \
	  echo "    and is never launched — startMonitoring still succeeds and"; \
	  echo "    DeviceActivityCenter().activities still lists the activity."; \
	  echo ""; \
	  exit 1; \
	fi

verify-project:
	@if [ ! -f "$(PBXPROJ)" ]; then \
	  echo "==> Skipping pbxproj checks — $(XCODEPROJ) not generated yet (run: make project)"; \
	  exit 0; \
	fi; \
	echo "==> Verifying $(PBXPROJ) — GateReport product type and embed phase"; \
	fail=0; \
	if grep -qF 'com.apple.product-type.extensionkit-extension' "$(PBXPROJ)"; then \
	  echo "    ok    productType com.apple.product-type.extensionkit-extension present"; \
	else \
	  echo "    FAIL  no extensionkit-extension productType in the pbxproj."; \
	  echo "          GateReport was generated as a plain app-extension. Upgrade"; \
	  echo "          XcodeGen to >= 2.42.0 and regenerate; if that is impossible,"; \
	  echo "          see the commented 'copy:' block on the GateReport dependency"; \
	  echo "          in $(SPEC)."; \
	  fail=1; \
	fi; \
	if grep -q 'dstSubfolderSpec = 16' "$(PBXPROJ)"; then \
	  echo "    ok    embed phase dstSubfolderSpec = 16 (Extensions/)"; \
	else \
	  echo "    FAIL  no copy-files phase with dstSubfolderSpec = 16."; \
	  echo "          GateReport is being embedded into PlugIns/ (spec 13) instead of"; \
	  echo "          Extensions/. This installs fine on device and costs a full App"; \
	  echo "          Store review cycle to discover (api-reference section 3, trap 3)."; \
	  fail=1; \
	fi; \
	if grep -qF 'EXTENSIONS_FOLDER_PATH' "$(PBXPROJ)"; then \
	  echo "    ok    embed phase dstPath references EXTENSIONS_FOLDER_PATH"; \
	else \
	  echo "    WARN  EXTENSIONS_FOLDER_PATH not referenced in any embed phase."; \
	fi; \
	n=$$(grep -c 'com.apple.product-type.app-extension' "$(PBXPROJ)" || true); \
	if [ "$$n" -ge 3 ]; then \
	  echo "    ok    $$n app-extension productType references (3 classic extensions)"; \
	else \
	  echo "    FAIL  expected at least 3 app-extension targets, found $$n."; \
	  fail=1; \
	fi; \
	exit $$fail

# ─────────────────────────────────────────────────────────────────────────────
# test — docs/06-build-plan.md step 3.11
#
# The Kernel is tested as a platform-agnostic SwiftPM package, so `swift test`
# runs with no Xcode and no device. Nothing else on this stack is testable
# anywhere: AuthorizationCenter, DeviceActivityCenter and ManagedSettingsStore
# are all unusable in a test process, and there is no Simulator support for any
# Screen Time API (docs/03-hard-constraints.md #11).
# ─────────────────────────────────────────────────────────────────────────────
test:
	@command -v $(SWIFT) >/dev/null 2>&1 || { \
	  echo ""; \
	  echo "ERROR: '$(SWIFT)' not found on PATH."; \
	  echo ""; \
	  echo "  macOS:  install Xcode, then"; \
	  echo "          sudo xcode-select -s /Applications/Xcode.app"; \
	  echo "  Linux:  install a toolchain from https://swift.org/download"; \
	  echo ""; \
	  exit 1; }
	@test -f $(TESTS_DIR)/Package.swift || { \
	  echo ""; \
	  echo "ERROR: $(TESTS_DIR)/Package.swift not found."; \
	  echo ""; \
	  echo "  The Kernel test package is created in Phase 3.11 of"; \
	  echo "  docs/06-build-plan.md. There is nothing to run yet."; \
	  echo ""; \
	  exit 1; }
	cd $(TESTS_DIR) && $(SWIFT) test

# ─────────────────────────────────────────────────────────────────────────────
# lint
# ─────────────────────────────────────────────────────────────────────────────
lint:
	@command -v $(SWIFTLINT) >/dev/null 2>&1 || { \
	  echo ""; \
	  echo "ERROR: '$(SWIFTLINT)' not found on PATH."; \
	  echo ""; \
	  echo "  Install:  brew install swiftlint"; \
	  echo "  Source:   https://github.com/realm/SwiftLint"; \
	  echo ""; \
	  exit 1; }
	$(SWIFTLINT) lint --quiet
	@if command -v $(PLUTIL) >/dev/null 2>&1; then \
	  echo "==> plutil -lint $(CONFIG_DIR)"; \
	  $(PLUTIL) -lint $(CONFIG_DIR)/*.plist $(CONFIG_DIR)/*.entitlements; \
	else \
	  echo "==> Skipping plutil -lint — '$(PLUTIL)' is macOS-only and is not on PATH."; \
	fi

# ─────────────────────────────────────────────────────────────────────────────
# clean
# ─────────────────────────────────────────────────────────────────────────────
clean:
	@echo "==> Removing the generated project and all build products"
	rm -rf $(XCODEPROJ)
	rm -rf DerivedData
	rm -rf .build $(TESTS_DIR)/.build
	rm -rf .swiftpm $(TESTS_DIR)/.swiftpm
	@echo "    Done. Run 'make project' to regenerate $(XCODEPROJ)."
