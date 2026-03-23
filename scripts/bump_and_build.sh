#!/bin/bash
# scripts/bump_and_build.sh — bump build number, compile-check both platforms, commit, push
#
# Usage:
#   ./scripts/bump_and_build.sh           # auto-increment build number
#   ./scripts/bump_and_build.sh 50        # set to a specific build number
#   ./scripts/bump_and_build.sh --force   # auto-increment, overwrite existing sentinel
#   ./scripts/bump_and_build.sh 50 --force  # set specific number, overwrite existing sentinel
#
# Rule: one bump → one build → one distribute.
# If a successful build sentinel already exists for the target build number, the script
# exits with an error. Pass --force to override (e.g. after fixing a compile error without
# re-bumping, or when re-running after a partial failure).
#
# On success: commits the bump, pushes to remote, writes build/last_build_success.
# On failure: exits non-zero and removes the sentinel so distribute.sh refuses to run.
#
# Run this BEFORE build-and-distribute.sh. Never run distribute without a fresh sentinel.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

PBXPROJ="MeshCoreApple.xcodeproj/project.pbxproj"
BUILD_STATUS="BUILD_STATUS.md"
SENTINEL="build/last_build_success"

# Colors
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[BUILD]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Parse args: optional build number and --force flag ---

FORCE=0
BUILD_ARG=""
for arg in "$@"; do
    if [ "$arg" = "--force" ]; then
        FORCE=1
    elif [[ "$arg" =~ ^[0-9]+$ ]]; then
        BUILD_ARG="$arg"
    fi
done

# --- 1. Determine target build number ---

# Warn if Xcode is open — it holds project.pbxproj in memory and may write back
# its cached version after we bump, silently reverting the build number.
if pgrep -xq "Xcode"; then
    warn "Xcode is running. It may overwrite project.pbxproj from its in-memory state"
    warn "after we bump the build number, causing build number drift."
    warn "Close Xcode before running this script to prevent that. Continuing anyway..."
fi

# Read the maximum CURRENT_PROJECT_VERSION across all entries (not just -m1).
# If the project is in a mixed state, we want the highest value so auto-increment
# stays ahead of all targets.
CURRENT=$(grep "CURRENT_PROJECT_VERSION" "$PBXPROJ" | grep -o '[0-9]*' | sort -n | tail -1)
VERSION=$(grep -m1 "MARKETING_VERSION" "$PBXPROJ" | grep -o '[0-9]*\.[0-9]*\.[0-9]*')

if [ -n "$BUILD_ARG" ]; then
    NEW_BUILD="$BUILD_ARG"
else
    NEW_BUILD=$((CURRENT + 1))
fi

# --- 1a. Sentinel guard: refuse to rebuild a number that already succeeded ---

if [ -f "$SENTINEL" ]; then
    SENTINEL_BUILD=$(head -1 "$SENTINEL")
    if [ "$SENTINEL_BUILD" = "$NEW_BUILD" ]; then
        if [ "$FORCE" -eq 0 ]; then
            echo -e "${RED}[ERROR]${NC} Build $NEW_BUILD already has a successful build sentinel ($(tail -1 "$SENTINEL"))."
            echo -e "${RED}[ERROR]${NC} One bump → one build → one distribute. Don't rebuild a number that's ready to ship."
            echo -e "        To override: ${YELLOW}./scripts/bump_and_build.sh $NEW_BUILD --force${NC}"
            echo -e "        To advance:  ${YELLOW}./scripts/bump_and_build.sh${NC} (auto-increments to $((NEW_BUILD + 1)))"
            exit 1
        else
            warn "--force passed — overwriting existing build $NEW_BUILD sentinel ($(tail -1 "$SENTINEL"))."
        fi
    fi
fi

# --- 2. Bump build number in ALL targets ---
# The sed pattern matches any existing numeric value, not just $CURRENT.
# This is intentional: if the project is in a mixed state (different targets
# at different build numbers), ALL entries are brought to $NEW_BUILD atomically
# regardless of their starting value. Using $CURRENT as the match pattern would
# silently leave entries at any other value untouched.

sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9][0-9]*/CURRENT_PROJECT_VERSION = $NEW_BUILD/g" "$PBXPROJ"
log "Build number: $CURRENT → $NEW_BUILD (v$VERSION) — all targets"

# --- 2a. Readback verification: every entry must equal NEW_BUILD exactly ---
# This catches any entry the sed didn't update (format mismatch, file encoding
# issue, entries not ending in semicolon, etc.).

WRONG_ENTRIES=$(grep "CURRENT_PROJECT_VERSION" "$PBXPROJ" | grep -v "= $NEW_BUILD;" || true)
if [ -n "$WRONG_ENTRIES" ]; then
    error "Build number mismatch after sed — some entries were NOT updated to $NEW_BUILD:"
    echo "$WRONG_ENTRIES" >&2
    error "This should not happen. Check $PBXPROJ for unexpected formatting."
    exit 1
fi
UPDATED_COUNT=$(grep -c "CURRENT_PROJECT_VERSION = $NEW_BUILD;" "$PBXPROJ" || true)
log "Verified: $UPDATED_COUNT entries all set to $NEW_BUILD"

# Sanity: we expect exactly 6 entries (3 targets × Debug + Release).
# Warn if the count is unexpected so we notice if targets were added/removed.
EXPECTED_COUNT=6
if [ "$UPDATED_COUNT" -ne "$EXPECTED_COUNT" ]; then
    warn "Expected $EXPECTED_COUNT CURRENT_PROJECT_VERSION entries but found $UPDATED_COUNT."
    warn "A target may have been added or removed. Verify project structure is correct."
fi

# --- 3. Update BUILD_STATUS.md ---

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
if [ -f "$BUILD_STATUS" ]; then
    sed -i '' \
        -e "s/^\*\*Current Build:\*\* Build [0-9]* (v[0-9.]*)/\*\*Current Build:\*\* Build $NEW_BUILD (v$VERSION)/" \
        -e "s/^\*\*Last Updated:\*\* .*/\*\*Last Updated:\*\* $TIMESTAMP/" \
        "$BUILD_STATUS"
    log "Updated $BUILD_STATUS"
fi

# --- 4. Archive — iOS (compile + link + package check, no signing) ---
# Use 'archive' not 'build': catches missing entitlements, plist errors, and
# any step that only runs during the archive phase (the same steps distribute uses).

log "Archiving iOS (compile check)..."
mkdir -p build
if ! xcodebuild archive \
    -project MeshCoreApple.xcodeproj \
    -scheme MeshCoreApple \
    -destination "generic/platform=iOS" \
    -configuration Release \
    -archivePath /tmp/bump_build_ios.xcarchive \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee /tmp/bump_build_ios.log | grep -E "error:|warning:|ARCHIVE SUCCEEDED|ARCHIVE FAILED"; then
    error "iOS archive failed — check /tmp/bump_build_ios.log"
    rm -f "$SENTINEL"
    exit 1
fi

if ! grep -q "ARCHIVE SUCCEEDED" /tmp/bump_build_ios.log; then
    error "iOS archive failed — check /tmp/bump_build_ios.log"
    rm -f "$SENTINEL"
    exit 1
fi
log "iOS: ARCHIVE SUCCEEDED"

# --- 5. Archive — macOS (compile + link + package check, no signing) ---

log "Archiving macOS (compile check)..."
if ! xcodebuild archive \
    -project MeshCoreApple.xcodeproj \
    -scheme MeshCoreApple-macOS \
    -destination "generic/platform=macOS" \
    -configuration Release \
    -archivePath /tmp/bump_build_macos.xcarchive \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee /tmp/bump_build_macos.log | grep -E "error:|warning:|ARCHIVE SUCCEEDED|ARCHIVE FAILED"; then
    error "macOS archive failed — check /tmp/bump_build_macos.log"
    rm -f "$SENTINEL"
    exit 1
fi

if ! grep -q "ARCHIVE SUCCEEDED" /tmp/bump_build_macos.log; then
    error "macOS archive failed — check /tmp/bump_build_macos.log"
    rm -f "$SENTINEL"
    exit 1
fi
log "macOS: ARCHIVE SUCCEEDED"

# --- 6. Commit and push the bump ---

log "Committing build bump..."
git add "$PBXPROJ"
[ -f "$BUILD_STATUS" ] && git add "$BUILD_STATUS"

if ! git commit -m "chore: bump build to $NEW_BUILD (v$VERSION)

    error "git commit failed"
    rm -f "$SENTINEL"
    exit 1
fi
log "Committed: chore: bump build to $NEW_BUILD (v$VERSION)"

log "Pushing to remote..."
if ! git push; then
    error "git push failed — commit exists locally ($(git rev-parse --short HEAD))."
    error "Push manually: git push"
    error "Then re-run: ./scripts/bump_and_build.sh $NEW_BUILD --force"
    rm -f "$SENTINEL"
    exit 1
fi
log "Pushed"

# --- 7. Write sentinel (only after successful push) ---

printf "%s\n%s\n" "$NEW_BUILD" "$TIMESTAMP" > "$SENTINEL"

echo ""
echo -e "${GREEN}✓ Build $NEW_BUILD (v$VERSION) — archived (no signing), committed, pushed, ready to distribute.${NC}"
echo -e "  Next: ${YELLOW}./build-and-distribute.sh [ios|macos|all]${NC}"
echo ""
