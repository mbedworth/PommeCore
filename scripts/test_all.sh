#!/bin/bash
#
# Every automated gate, in the order that fails cheapest first.
#
#   1. Rule checks      — no compiler, instant
#   2. Package tests    — swift test, no simulator
#   3. App tests        — needs a booted-able simulator
#
# Exits non-zero on the first stage that fails, because a later stage's output
# is noise once an earlier one has told you what is wrong.
#
# The app stage is skipped with a clear message, not a failure, when the test
# target does not exist yet — see docs/TESTING.md for the one-time Xcode setup.
#
# Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[TEST]${NC} $*"; }
warn()  { echo -e "${YELLOW}[SKIP]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }

ONLY="${1:-all}"

# ---------------------------------------------------------------- rule checks
if [[ "$ONLY" == "all" || "$ONLY" == "rules" ]]; then
    info "Rule checks (scripts/check_rules.py)"
    if ! python3 scripts/check_rules.py; then
        fail "Critical Rule violation — fix before building"
        exit 1
    fi

    info "String catalog integrity (scripts/translate_strings.py --verify)"
    if ! python3 scripts/translate_strings.py --verify; then
        fail "Catalog verification failed"
        exit 1
    fi
fi

# -------------------------------------------------------------- package tests
if [[ "$ONLY" == "all" || "$ONLY" == "package" ]]; then
    info "MeshCoreKit package tests"
    if ! swift test --package-path Packages/MeshCoreKit 2>&1 | tail -20; then
        fail "Package tests failed"
        exit 1
    fi
fi

# ------------------------------------------------------------------ app tests
if [[ "$ONLY" == "all" || "$ONLY" == "app" ]]; then
    if ! xcodebuild -list -project PommeCore.xcodeproj 2>/dev/null | grep -q "PommeCoreTests"; then
        warn "No PommeCoreTests target in the project — app tests not run."
        warn "One-time setup: docs/TESTING.md > 'One-time setup (Xcode GUI)'."
        exit 0
    fi

    # Resolve a simulator rather than hardcoding a name. The documented command
    # named 'iPhone 16' and this machine has none — Xcode 27 ships 17-series
    # devices — so a pinned name rots silently into "destination not found".
    DEVICE_LINE=$(xcrun simctl list devices available 2>/dev/null \
                  | grep -E '^ +iPhone .*\([0-9A-F-]{36}\) \(Shut|^ +iPhone .*\([0-9A-F-]{36}\) \(Boot' \
                  | head -1)
    DEVICE=$(echo "$DEVICE_LINE" | sed -E 's/^ *(.*) \([0-9A-F-]{36}\).*/\1/')
    DEVICE_UDID=$(echo "$DEVICE_LINE" | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
    if [[ -z "$DEVICE" || -z "$DEVICE_UDID" ]]; then
        fail "No iPhone simulator available."
        fail "If 'simctl' printed 'Authorization is required to install the packages',"
        fail "Xcode's simulator support is not installed yet. Run, with your password:"
        fail "    sudo xcodebuild -runFirstLaunch"
        exit 1
    fi

    # Boot it and wait for it to actually be ready.
    #
    # Left to itself, xcodebuild boots the simulator and then tries to install
    # and launch the host app while SpringBoard is still starting, which fails
    # with Busy ("Application failed preflight checks") — reproducibly when this
    # stage follows the package tests, and not at all when the device happens to
    # already be booted from a previous run. That intermittency is the whole
    # problem: a gate that fails for reasons unrelated to the code teaches you to
    # rerun it until it passes, which is how a real failure gets waved through.
    # `bootstatus -b` blocks until the device reports ready.
    xcrun simctl boot "$DEVICE_UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$DEVICE_UDID" -b > /dev/null 2>&1 || true

    # A stale install of a previous build also produces the preflight failure.
    xcrun simctl uninstall "$DEVICE_UDID" com.mbedworth.meshcore 2>/dev/null || true

    info "App tests on $DEVICE"
    # PommeCoreTests, not PommeCore. The release scripts archive with
    # `-scheme PommeCore`, which Xcode autocreates; a shared scheme of that name
    # would replace it, and a hand-written archive action is not worth the risk
    # to the shipping path. See the comment in PommeCoreTests.xcscheme.
    #
    # A result bundle, and the count read back out of it, because **xcodebuild's
    # exit status does not tell you whether any test ran.** A scheme that builds
    # the bundle and runs nothing exits 0, and `-quiet` prints not one line about
    # it: the first run of this gate "passed" while printing no test output at
    # all, and the only way to tell the difference was to open the bundle. A gate
    # that can pass without running anything is the same defect as the four this
    # suite exists to catch.
    RESULT_BUNDLE="${TMPDIR:-/tmp}/pommecore_tests.xcresult"
    rm -rf "$RESULT_BUNDLE"
    xcodebuild test -scheme PommeCoreTests \
        -destination "id=$DEVICE_UDID" \
        -resultBundlePath "$RESULT_BUNDLE" \
        -quiet > "${TMPDIR:-/tmp}/pommecore_tests.log" 2>&1
    XC_STATUS=$?

    SUMMARY=$(xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>/dev/null)
    PASSED=$(echo "$SUMMARY" | sed -n 's/.*"passedTests" : \([0-9]*\).*/\1/p' | head -1)
    FAILED=$(echo "$SUMMARY" | sed -n 's/.*"failedTests" : \([0-9]*\).*/\1/p' | head -1)
    SKIPPED=$(echo "$SUMMARY" | sed -n 's/.*"skippedTests" : \([0-9]*\).*/\1/p' | head -1)

    if [[ $XC_STATUS -ne 0 ]]; then
        fail "App tests failed — see ${TMPDIR:-/tmp}/pommecore_tests.log"
        grep -E "error:|Testing failed:|failed to launch|preflight" "${TMPDIR:-/tmp}/pommecore_tests.log" | sort -u | head -10
        exit 1
    fi
    if [[ -z "${PASSED:-}" || "${PASSED:-0}" -eq 0 ]]; then
        fail "App tests reported 0 tests run. xcodebuild exited 0, which means"
        fail "nothing was executed — check the scheme's Test action."
        exit 1
    fi
    if [[ "${FAILED:-0}" -ne 0 ]]; then
        fail "$FAILED app test(s) failed"
        exit 1
    fi
    info "App tests: $PASSED passed, ${SKIPPED:-0} skipped"

    # Zero warnings is a release requirement, so a warning introduced in app
    # sources fails here rather than surfacing during an archive.
    APP_WARNINGS=$(grep "warning:" "${TMPDIR:-/tmp}/pommecore_tests.log" 2>/dev/null \
                   | grep -vE "Packages/|DerivedData|SourcePackages" | sort -u)
    if [[ -n "$APP_WARNINGS" ]]; then
        fail "App sources produced warnings — zero are allowed before a build:"
        echo "$APP_WARNINGS" | sed "s|$PWD/||" | head -20
        exit 1
    fi
fi

info "All gates passed"
