#!/bin/bash
set -euo pipefail

# MeshCoreApple Distribute Script
# Archives and uploads to App Store Connect / TestFlight.
#
# MUST run scripts/bump_and_build.sh first — this script refuses to run
# if a clean compile-check hasn't been completed for the current build number.
#
# Usage:
#   ./scripts/bump_and_build.sh [build_number]   # bump, compile-check, write sentinel
#   git add -A && git commit && git push          # commit the bump
#   ./build-and-distribute.sh [ios|macos|all] [--archive-only]

SCHEME="MeshCoreApple"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_DIR="$BUILD_DIR/archives"
EXPORT_DIR="$BUILD_DIR/exports"
SENTINEL="$BUILD_DIR/last_build_success"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[DIST]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Pre-flight: verify a clean build exists for the current build number ---

cd "$PROJECT_DIR"
VERSION=$(grep "MARKETING_VERSION" MeshCoreApple.xcodeproj/project.pbxproj | head -1 | grep -o '[0-9]*\.[0-9]*\.[0-9]*')
BUILD=$(grep "CURRENT_PROJECT_VERSION" MeshCoreApple.xcodeproj/project.pbxproj | head -1 | grep -o '[0-9]*')

if [ ! -f "$SENTINEL" ]; then
    error "No build sentinel found. Run ./scripts/bump_and_build.sh first."
fi

SENTINEL_BUILD=$(head -1 "$SENTINEL")
if [ "$SENTINEL_BUILD" != "$BUILD" ]; then
    error "Sentinel is for build $SENTINEL_BUILD but project is at build $BUILD. Re-run ./scripts/bump_and_build.sh."
fi

# Stale check: sentinel must be less than 24 hours old
SENTINEL_AGE=$(( $(date +%s) - $(stat -f %m "$SENTINEL") ))
if [ "$SENTINEL_AGE" -gt 86400 ]; then
    warn "Build sentinel is $(( SENTINEL_AGE / 3600 ))h old — consider re-running bump_and_build.sh for a fresh compile check."
fi

log "Pre-flight passed: clean build confirmed for v$VERSION build $BUILD"

# --- Pre-flight: verify App Store Connect API key exists ---

ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
if [[ ! -f "$ASC_KEY_PATH" ]]; then
    error "App Store Connect API key not found at $ASC_KEY_PATH
       Copy AuthKey_$ASC_KEY_ID.p8 there and chmod 600 it, then re-run."
fi

# Parse args
TARGET="${1:-all}"
ARCHIVE_ONLY="${2:-}"

log "MeshCoreApple v$VERSION build $BUILD"
log "Target: $TARGET"

# Clean build directory
mkdir -p "$ARCHIVE_DIR" "$EXPORT_DIR"

# Archive iOS
if [[ "$TARGET" == "ios" || "$TARGET" == "all" ]]; then
    log "Archiving iOS..."
    xcodebuild archive \
        -project MeshCoreApple.xcodeproj \
        -scheme "$SCHEME" \
        -destination "generic/platform=iOS" \
        -archivePath "$ARCHIVE_DIR/MeshCore-iOS-$BUILD.xcarchive" \
        -allowProvisioningUpdates \
        CODE_SIGN_STYLE=Automatic \
        2>&1 | tee /tmp/xcodebuild-ios.log | tail -20
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        error "iOS archive failed — check /tmp/xcodebuild-ios.log"
    fi
    log "iOS archive complete: MeshCore-iOS-$BUILD.xcarchive"

    if [[ "$ARCHIVE_ONLY" != "--archive-only" ]]; then
        log "Uploading iOS to App Store Connect..."
        xcodebuild -exportArchive \
            -archivePath "$ARCHIVE_DIR/MeshCore-iOS-$BUILD.xcarchive" \
            -exportOptionsPlist "$PROJECT_DIR/ExportOptions-AppStore.plist" \
            -exportPath "$EXPORT_DIR/iOS-$BUILD" \
            -allowProvisioningUpdates \
            2>&1 | tee /tmp/xcodebuild-ios-export.log | tail -20
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            error "iOS export failed — check /tmp/xcodebuild-ios-export.log"
        fi
        log "iOS uploaded to App Store Connect"
    fi
fi

# Archive macOS
if [[ "$TARGET" == "macos" || "$TARGET" == "all" ]]; then
    log "Archiving macOS..."
    xcodebuild archive \
        -project MeshCoreApple.xcodeproj \
        -scheme "MeshCoreApple-macOS" \
        -destination "generic/platform=macOS" \
        -archivePath "$ARCHIVE_DIR/MeshCore-macOS-$BUILD.xcarchive" \
        -allowProvisioningUpdates \
        CODE_SIGN_STYLE=Automatic \
        2>&1 | tee /tmp/xcodebuild-macos.log | tail -20
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        error "macOS archive failed — check /tmp/xcodebuild-macos.log"
    fi
    log "macOS archive complete: MeshCore-macOS-$BUILD.xcarchive"

    if [[ "$ARCHIVE_ONLY" != "--archive-only" ]]; then
        log "Uploading macOS to App Store Connect..."
        xcodebuild -exportArchive \
            -archivePath "$ARCHIVE_DIR/MeshCore-macOS-$BUILD.xcarchive" \
            -exportOptionsPlist "$PROJECT_DIR/ExportOptions-AppStore.plist" \
            -exportPath "$EXPORT_DIR/macOS-$BUILD" \
            -allowProvisioningUpdates \
            2>&1 | tee /tmp/xcodebuild-macos-export.log | tail -20
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            error "macOS export failed — check /tmp/xcodebuild-macos-export.log"
        fi
        log "macOS uploaded to App Store Connect"
    fi
fi

log "Done! v$VERSION build $BUILD"
log "Check App Store Connect → TestFlight for processing status"
