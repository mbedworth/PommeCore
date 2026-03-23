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

CURRENT=$(grep -m1 "CURRENT_PROJECT_VERSION" "$PBXPROJ" | grep -o '[0-9]*' | head -1)
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
# sed replaces every CURRENT_PROJECT_VERSION occurrence (global flag),
# so all targets — iOS, macOS, watchOS — are updated atomically.

sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PBXPROJ"
log "Build number: $CURRENT → $NEW_BUILD (v$VERSION) — all targets"

# Verify all entries were updated (sanity check)
UPDATED_COUNT=$(grep -c "CURRENT_PROJECT_VERSION = $NEW_BUILD;" "$PBXPROJ" || true)
OLD_REMAINING=$(grep -c "CURRENT_PROJECT_VERSION = $CURRENT;" "$PBXPROJ" 2>/dev/null || true)
if [ "$OLD_REMAINING" -gt 0 ]; then
    error "$OLD_REMAINING target(s) still on old build $CURRENT — sed may have missed entries"
    exit 1
fi
log "Verified: $UPDATED_COUNT entries all updated to $NEW_BUILD"

# --- 3. Update BUILD_STATUS.md ---

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
if [ -f "$BUILD_STATUS" ]; then
    sed -i '' \
        -e "s/^\*\*Current Build:\*\* Build [0-9]* (v[0-9.]*)/\*\*Current Build:\*\* Build $NEW_BUILD (v$VERSION)/" \
        -e "s/^\*\*Last Updated:\*\* .*/\*\*Last Updated:\*\* $TIMESTAMP/" \
        "$BUILD_STATUS"
    log "Updated $BUILD_STATUS"
fi

# --- 4. Clean build — iOS (compile check, no signing) ---

log "Building iOS (compile check)..."
mkdir -p build
if ! xcodebuild \
    -project MeshCoreApple.xcodeproj \
    -scheme MeshCoreApple \
    -destination "generic/platform=iOS Simulator" \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    clean build \
    2>&1 | tee /tmp/bump_build_ios.log | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED"; then
    error "iOS build failed — check /tmp/bump_build_ios.log"
    rm -f "$SENTINEL"
    exit 1
fi

if ! grep -q "BUILD SUCCEEDED" /tmp/bump_build_ios.log; then
    error "iOS build failed — check /tmp/bump_build_ios.log"
    rm -f "$SENTINEL"
    exit 1
fi
log "iOS: BUILD SUCCEEDED"

# --- 5. Clean build — macOS (compile check, no signing) ---

log "Building macOS (compile check)..."
if ! xcodebuild \
    -project MeshCoreApple.xcodeproj \
    -scheme MeshCoreApple-macOS \
    -destination "generic/platform=macOS" \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    clean build \
    2>&1 | tee /tmp/bump_build_macos.log | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED"; then
    error "macOS build failed — check /tmp/bump_build_macos.log"
    rm -f "$SENTINEL"
    exit 1
fi

if ! grep -q "BUILD SUCCEEDED" /tmp/bump_build_macos.log; then
    error "macOS build failed — check /tmp/bump_build_macos.log"
    rm -f "$SENTINEL"
    exit 1
fi
log "macOS: BUILD SUCCEEDED"

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
echo -e "${GREEN}✓ Build $NEW_BUILD (v$VERSION) — compiled, committed, pushed, ready to distribute.${NC}"
echo -e "  Next: ${YELLOW}./build-and-distribute.sh [ios|macos|all]${NC}"
echo ""
