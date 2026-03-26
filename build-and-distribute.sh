#!/bin/bash
set -euo pipefail

# MeshCoreApple Distribute Script
# Bumps build number, commits, pushes, then archives and uploads to TestFlight.
#
# MUST run scripts/bump_and_build.sh first to verify code compiles cleanly.
#
# Workflow:
#   1. ./scripts/bump_and_build.sh          # verify code compiles (no bump yet)
#   2. ./build-and-distribute.sh [ios|macos|all]  # bump, commit, push, archive, upload
#
# When TARGET=all, BOTH platforms are archived before EITHER is uploaded.
# A signing or provisioning failure on one platform will not cause a partial
# upload of the other.
#
# Usage:
#   ./build-and-distribute.sh [ios|macos|all] [--archive-only|--upload-only]
#
# Modes:
#   (no mode)    — archive, bump, commit, push, upload (full workflow)
#   --archive-only  — archive only, skip bump/upload (for verification)
#   --upload-only   — upload only, reuse existing build, skip archive/bump

SCHEME="MeshCoreApple"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
# Archives go to the standard Xcode location so Organizer sees them automatically.
# Subdirectory is today's date; mkdir -p creates it if needed.
ARCHIVE_DATE=$(date '+%Y-%m-%d')
ARCHIVE_DIR="$HOME/Library/Developer/Xcode/Archives/$ARCHIVE_DATE"
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

# --- Pre-flight: read current build number (don't bump yet) ---

cd "$PROJECT_DIR"
PBXPROJ="MeshCoreApple.xcodeproj/project.pbxproj"
VERSION=$(grep "MARKETING_VERSION" "$PBXPROJ" | head -1 | grep -o '[0-9]*\.[0-9]*\.[0-9]*')
CURRENT=$(grep "CURRENT_PROJECT_VERSION" "$PBXPROJ" | grep -o '[0-9]*' | sort -n | tail -1)
NEW_BUILD=$((CURRENT + 1))

log "Pre-flight: Ready to distribute build $CURRENT (v$VERSION)"
log "Next build number will be: $NEW_BUILD (only bumped after successful archiving)"

# --- Pre-flight: verify App Store Connect API key exists ---

ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
if [[ ! -f "$ASC_KEY_PATH" ]]; then
    error "App Store Connect API key not found at $ASC_KEY_PATH
       Copy AuthKey_$ASC_KEY_ID.p8 there and chmod 600 it, then re-run."
fi

# Parse args
TARGET="${1:-all}"
MODE="${2:-}"

# Validate mode
if [[ -n "$MODE" && "$MODE" != "--archive-only" && "$MODE" != "--upload-only" ]]; then
    error "Unknown mode: $MODE. Use --archive-only or --upload-only"
fi

# For upload-only, we reuse existing archives (don't bump)
if [[ "$MODE" == "--upload-only" ]]; then
    log "Upload-only mode — reusing build $CURRENT archives"
    SKIP_BUMP=1
else
    SKIP_BUMP=0
    log "MeshCoreApple v$VERSION build $CURRENT (archiving...)"
fi

log "Target: $TARGET"

# Create archive and export directories
mkdir -p "$ARCHIVE_DIR" "$EXPORT_DIR"

# Archive names — scheme-based, version+build visible at a glance in Organizer.
IOS_ARCHIVE="$ARCHIVE_DIR/MeshCoreApple v$VERSION ($CURRENT).xcarchive"
MACOS_ARCHIVE="$ARCHIVE_DIR/MeshCoreApple-macOS v$VERSION ($CURRENT).xcarchive"

# ============================================================
# PHASE 1 — ARCHIVE (both platforms before any upload starts)
# A failure here stops everything before any upload is attempted.
# (skipped with --upload-only mode)
# ============================================================

if [[ "$SKIP_BUMP" == "1" ]]; then
    log "Skipping archive phase (upload-only mode)"
else

if [[ "$TARGET" == "ios" || "$TARGET" == "all" ]]; then
    log "Archiving iOS..."
    # Unlock the login keychain before codesign runs so xcodebuild can access signing
    # certificates without triggering a macOS keychain authorization event that would
    # invalidate Xcode's GUI Apple ID session.
    security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
    xcodebuild archive \
        -project MeshCoreApple.xcodeproj \
        -scheme "$SCHEME" \
        -destination "generic/platform=iOS" \
        -archivePath "$IOS_ARCHIVE" \
        CODE_SIGN_STYLE=Automatic \
        OTHER_CODE_SIGN_FLAGS="--keychain ~/Library/Keychains/login.keychain-db" \
        2>&1 | tee /tmp/xcodebuild-ios.log | tail -20
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        error "iOS archive failed — check /tmp/xcodebuild-ios.log"
    fi
    log "iOS archive complete → $(basename "$IOS_ARCHIVE")"
    log "  Path: $IOS_ARCHIVE"
fi

if [[ "$TARGET" == "macos" || "$TARGET" == "all" ]]; then
    log "Archiving macOS..."
    security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
    xcodebuild archive \
        -project MeshCoreApple.xcodeproj \
        -scheme "MeshCoreApple-macOS" \
        -destination "generic/platform=macOS" \
        -archivePath "$MACOS_ARCHIVE" \
        CODE_SIGN_STYLE=Automatic \
        OTHER_CODE_SIGN_FLAGS="--keychain ~/Library/Keychains/login.keychain-db" \
        2>&1 | tee /tmp/xcodebuild-macos.log | tail -20
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        error "macOS archive failed — check /tmp/xcodebuild-macos.log"
    fi
    log "macOS archive complete → $(basename "$MACOS_ARCHIVE")"
    log "  Path: $MACOS_ARCHIVE"
fi

if [[ "$TARGET" == "all" ]]; then
    log "Both archives complete — proceeding to bump and upload phase"
fi

fi  # end SKIP_BUMP check

# ============================================================
# PHASE 1B — BUMP BUILD NUMBER (only after archiving succeeds)
# This ensures build numbers are never wasted on failed distributions.
# (skipped with --upload-only mode)
# ============================================================

if [[ "$SKIP_BUMP" == "1" ]]; then
    log "Skipping bump phase (upload-only mode, reusing build $CURRENT)"
else

log "Bumping build number from $CURRENT to $NEW_BUILD..."
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9][0-9]*/CURRENT_PROJECT_VERSION = $NEW_BUILD/g" "$PBXPROJ"

WRONG_ENTRIES=$(grep "CURRENT_PROJECT_VERSION" "$PBXPROJ" | grep -v "= $NEW_BUILD;" || true)
if [ -n "$WRONG_ENTRIES" ]; then
    error "Build number mismatch after sed — some entries were NOT updated to $NEW_BUILD"
fi

log "Verified: all CURRENT_PROJECT_VERSION entries set to $NEW_BUILD"

log "Committing build bump..."
git add "$PBXPROJ"
if ! git commit -m "chore: bump build to $NEW_BUILD (v$VERSION)

    error "git commit failed"
fi

log "Pushing to remote..."
if ! git push; then
    error "git push failed"
fi

log "Build $NEW_BUILD bumped, committed, and pushed"

fi  # end SKIP_BUMP check

# ============================================================
# PHASE 2 — UPLOAD (skipped entirely with --archive-only)
# Both archives exist at this point; either upload can fail
# independently without affecting the other archive.
# ============================================================

if [[ "$MODE" == "--archive-only" ]]; then
    log "Archive-only mode — skipping uploads"
    log "Done! v$VERSION build $CURRENT archived. Organizer path: $ARCHIVE_DIR"
    exit 0
fi

if [[ "$TARGET" == "ios" || "$TARGET" == "all" ]]; then
    log "Uploading iOS to App Store Connect..."
    xcodebuild -exportArchive \
        -archivePath "$IOS_ARCHIVE" \
        -exportOptionsPlist "$PROJECT_DIR/ExportOptions-AppStore.plist" \
        -exportPath "$EXPORT_DIR/iOS-$NEW_BUILD" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$ASC_KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_KEY_ISSUER" \
        2>&1 | tee /tmp/xcodebuild-ios-export.log | tail -20
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        error "iOS export failed — check /tmp/xcodebuild-ios-export.log"
    fi
    log "iOS uploaded to App Store Connect"
fi

if [[ "$TARGET" == "macos" || "$TARGET" == "all" ]]; then
    log "Uploading macOS to App Store Connect..."
    xcodebuild -exportArchive \
        -archivePath "$MACOS_ARCHIVE" \
        -exportOptionsPlist "$PROJECT_DIR/ExportOptions-AppStore.plist" \
        -exportPath "$EXPORT_DIR/macOS-$NEW_BUILD" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$ASC_KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_KEY_ISSUER" \
        2>&1 | tee /tmp/xcodebuild-macos-export.log | tail -20
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        error "macOS export failed — check /tmp/xcodebuild-macos-export.log"
    fi
    log "macOS uploaded to App Store Connect"
fi

log "Done! v$VERSION build $NEW_BUILD uploaded to App Store Connect"
log "Check App Store Connect → TestFlight for processing status"
