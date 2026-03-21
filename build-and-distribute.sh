#!/bin/bash
set -e

# MeshCoreApple Build & Distribute Script
# Usage: ./build-and-distribute.sh [ios|macos|all] [--archive-only]

SCHEME="MeshCoreApple"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_DIR="$BUILD_DIR/archives"
EXPORT_DIR="$BUILD_DIR/exports"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[BUILD]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Parse args
TARGET="${1:-all}"
ARCHIVE_ONLY="${2:-}"

# Get version info
cd "$PROJECT_DIR"
VERSION=$(grep "MARKETING_VERSION" MeshCoreApple.xcodeproj/project.pbxproj | head -1 | grep -o '[0-9]*\.[0-9]*\.[0-9]*')
BUILD=$(grep "CURRENT_PROJECT_VERSION" MeshCoreApple.xcodeproj/project.pbxproj | head -1 | grep -o '[0-9]*')

log "MeshCoreApple v$VERSION build $BUILD"
log "Target: $TARGET"

# Clean build directory
mkdir -p "$ARCHIVE_DIR" "$EXPORT_DIR"

# Bump build number
log "Bumping build number..."
./bump-build.sh
BUILD=$(grep "CURRENT_PROJECT_VERSION" MeshCoreApple.xcodeproj/project.pbxproj | head -1 | grep -o '[0-9]*')
log "New build number: $BUILD"

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
        2>&1 | tail -5

    if [ $? -eq 0 ]; then
        log "iOS archive complete: MeshCore-iOS-$BUILD.xcarchive"
    else
        error "iOS archive failed"
    fi

    if [[ "$ARCHIVE_ONLY" != "--archive-only" ]]; then
        log "Uploading iOS to App Store Connect..."
        xcodebuild -exportArchive \
            -archivePath "$ARCHIVE_DIR/MeshCore-iOS-$BUILD.xcarchive" \
            -exportOptionsPlist "$PROJECT_DIR/ExportOptions-AppStore.plist" \
            -exportPath "$EXPORT_DIR/iOS-$BUILD" \
            -allowProvisioningUpdates \
            2>&1 | tail -5
        log "iOS uploaded to App Store Connect"
    fi
fi

# Archive macOS (Catalyst)
if [[ "$TARGET" == "macos" || "$TARGET" == "all" ]]; then
    log "Archiving macOS (Catalyst)..."
    xcodebuild archive \
        -project MeshCoreApple.xcodeproj \
        -scheme "$SCHEME" \
        -destination "generic/platform=macOS,variant=Mac Catalyst" \
        -archivePath "$ARCHIVE_DIR/MeshCore-macOS-$BUILD.xcarchive" \
        -allowProvisioningUpdates \
        CODE_SIGN_STYLE=Automatic \
        2>&1 | tail -5

    if [ $? -eq 0 ]; then
        log "macOS archive complete: MeshCore-macOS-$BUILD.xcarchive"
    else
        error "macOS archive failed"
    fi

    if [[ "$ARCHIVE_ONLY" != "--archive-only" ]]; then
        log "Uploading macOS to App Store Connect..."
        xcodebuild -exportArchive \
            -archivePath "$ARCHIVE_DIR/MeshCore-macOS-$BUILD.xcarchive" \
            -exportOptionsPlist "$PROJECT_DIR/ExportOptions-AppStore.plist" \
            -exportPath "$EXPORT_DIR/macOS-$BUILD" \
            -allowProvisioningUpdates \
            2>&1 | tail -5
        log "macOS uploaded to App Store Connect"
    fi
fi

# Git commit and push
log "Committing build $BUILD..."
git add -A
git commit -m "build: v$VERSION build $BUILD — archive and distribute" 2>/dev/null || true
git push

log "Done! v$VERSION build $BUILD"
log "Check App Store Connect → TestFlight for processing status"
