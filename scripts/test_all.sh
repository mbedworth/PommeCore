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
    DEVICE=$(xcrun simctl list devices available 2>/dev/null \
             | grep -oE '^ +iPhone [^(]+' | head -1 | sed 's/^ *//;s/ *$//')
    if [[ -z "$DEVICE" ]]; then
        fail "No iPhone simulator available."
        fail "If 'simctl' printed 'Authorization is required to install the packages',"
        fail "Xcode's simulator support is not installed yet. Run, with your password:"
        fail "    sudo xcodebuild -runFirstLaunch"
        exit 1
    fi

    info "App tests on $DEVICE"
    if ! xcodebuild test -scheme PommeCore \
            -destination "platform=iOS Simulator,name=$DEVICE" \
            -quiet 2>&1 | tail -40; then
        fail "App tests failed"
        exit 1
    fi
fi

info "All gates passed"
