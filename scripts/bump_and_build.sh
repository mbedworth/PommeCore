#!/bin/bash
# scripts/bump_and_build.sh — bump build number, compile-check both platforms, update docs
#
# Usage:
#   ./scripts/bump_and_build.sh          # auto-increment build number
#   ./scripts/bump_and_build.sh 50       # set to a specific build number
#
# On success: writes build/last_build_success with the build number.
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

# --- 1. Bump build number ---

CURRENT=$(grep -m1 "CURRENT_PROJECT_VERSION" "$PBXPROJ" | grep -o '[0-9]*' | head -1)
VERSION=$(grep -m1 "MARKETING_VERSION" "$PBXPROJ" | grep -o '[0-9]*\.[0-9]*\.[0-9]*')

if [ -n "${1:-}" ]; then
    NEW_BUILD="$1"
else
    NEW_BUILD=$((CURRENT + 1))
fi

sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PBXPROJ"
log "Build number: $CURRENT → $NEW_BUILD (v$VERSION)"

# --- 2. Update BUILD_STATUS.md ---

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
if [ -f "$BUILD_STATUS" ]; then
    # Update the Current Build line and Last Updated line
    sed -i '' \
        -e "s/^\*\*Current Build:\*\* Build [0-9]* (v[0-9.]*)/\*\*Current Build:\*\* Build $NEW_BUILD (v$VERSION)/" \
        -e "s/^\*\*Last Updated:\*\* .*/\*\*Last Updated:\*\* $TIMESTAMP/" \
        "$BUILD_STATUS"
    log "Updated $BUILD_STATUS"
fi

# --- 3. Clean build — iOS (compile check, no signing) ---

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

# --- 4. Clean build — macOS (compile check, no signing) ---

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

# --- 5. Write sentinel ---

mkdir -p build
printf "%s\n%s\n" "$NEW_BUILD" "$TIMESTAMP" > "$SENTINEL"

echo ""
echo -e "${GREEN}✓ Build $NEW_BUILD (v$VERSION) succeeded — ready to distribute.${NC}"
echo -e "  Next: ${YELLOW}./build-and-distribute.sh [ios|macos|all]${NC}"
echo ""
