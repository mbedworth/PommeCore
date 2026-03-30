#!/bin/bash
set -euo pipefail

# MeshCoreApple Distribute Script
# Bumps build number, archives with signing, and uploads to TestFlight.
#
# MUST run scripts/test_build.sh first to verify code compiles cleanly.
#
# Workflow:
#   1. ./scripts/test_build.sh              # verify code compiles (no bump yet)
#   2. ./build-and-distribute.sh [ios|macos|all]  # bump, archive, upload
#
# The build number is bumped BEFORE archiving so the uploaded binary
# contains the correct build number. If archiving fails, the bump is
# rolled back automatically.
#
# Usage:
#   ./build-and-distribute.sh [ios|macos|all]

SCHEME="MeshCoreApple"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_DATE=$(date '+%Y-%m-%d')
ARCHIVE_DIR="$HOME/Library/Developer/Xcode/Archives/$ARCHIVE_DATE"
EXPORT_DIR="$BUILD_DIR/exports"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[DIST]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Pre-flight ---

cd "$PROJECT_DIR"
PBXPROJ="MeshCoreApple.xcodeproj/project.pbxproj"
VERSION=$(grep "MARKETING_VERSION" "$PBXPROJ" | head -1 | grep -o '[0-9]*\.[0-9]*\.[0-9]*')
CURRENT=$(grep "CURRENT_PROJECT_VERSION" "$PBXPROJ" | grep -o '[0-9]*' | sort -n | tail -1)
NEW_BUILD=$((CURRENT + 1))

ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
if [[ ! -f "$ASC_KEY_PATH" ]]; then
    error "App Store Connect API key not found at $ASC_KEY_PATH"
fi

TARGET="${1:-all}"
log "Distributing v$VERSION: build $CURRENT → $NEW_BUILD (target: $TARGET)"

# Create directories
mkdir -p "$ARCHIVE_DIR" "$EXPORT_DIR"

# Archive names use the NEW build number
IOS_ARCHIVE="$ARCHIVE_DIR/MeshCoreApple v$VERSION ($NEW_BUILD).xcarchive"
MACOS_ARCHIVE="$ARCHIVE_DIR/MeshCoreApple-macOS v$VERSION ($NEW_BUILD).xcarchive"

# ============================================================
# PHASE 1 — BUMP BUILD NUMBER (before archiving)
# The archive must contain the new build number so TestFlight
# receives the correct version.
# ============================================================

log "Bumping build number from $CURRENT to $NEW_BUILD..."
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9][0-9]*/CURRENT_PROJECT_VERSION = $NEW_BUILD/g" "$PBXPROJ"

WRONG_ENTRIES=$(grep "CURRENT_PROJECT_VERSION" "$PBXPROJ" | grep -v "= $NEW_BUILD;" || true)
if [ -n "$WRONG_ENTRIES" ]; then
    error "Build number mismatch after sed — some entries were NOT updated to $NEW_BUILD"
fi
log "Verified: all CURRENT_PROJECT_VERSION entries set to $NEW_BUILD"

# ============================================================
# PHASE 2 — ARCHIVE (with new build number)
# If archiving fails, we roll back the bump.
# ============================================================

rollback_bump() {
    warn "Rolling back build number to $CURRENT..."
    sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9][0-9]*/CURRENT_PROJECT_VERSION = $CURRENT/g" "$PBXPROJ"
    error "Archive failed — build number rolled back to $CURRENT"
}

if [[ "$TARGET" == "ios" || "$TARGET" == "all" ]]; then
    log "Archiving iOS (v$VERSION build $NEW_BUILD)..."
    security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
    if ! xcodebuild archive \
        -project MeshCoreApple.xcodeproj \
        -scheme "$SCHEME" \
        -destination "generic/platform=iOS" \
        -archivePath "$IOS_ARCHIVE" \
        -allowProvisioningUpdates \
        CODE_SIGN_STYLE=Automatic \
        OTHER_CODE_SIGN_FLAGS="--keychain ~/Library/Keychains/login.keychain-db" \
        2>&1 | tee /tmp/xcodebuild-ios.log | tail -20; then
        rollback_bump
    fi
    if ! grep -q "ARCHIVE SUCCEEDED" /tmp/xcodebuild-ios.log; then
        rollback_bump
    fi
    log "iOS archive complete → v$VERSION build $NEW_BUILD"
fi

if [[ "$TARGET" == "macos" || "$TARGET" == "all" ]]; then
    log "Archiving macOS (v$VERSION build $NEW_BUILD)..."
    security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
    if ! xcodebuild archive \
        -project MeshCoreApple.xcodeproj \
        -scheme "MeshCoreApple-macOS" \
        -destination "generic/platform=macOS" \
        -archivePath "$MACOS_ARCHIVE" \
        -allowProvisioningUpdates \
        CODE_SIGN_STYLE=Automatic \
        OTHER_CODE_SIGN_FLAGS="--keychain ~/Library/Keychains/login.keychain-db" \
        2>&1 | tee /tmp/xcodebuild-macos.log | tail -20; then
        rollback_bump
    fi
    if ! grep -q "ARCHIVE SUCCEEDED" /tmp/xcodebuild-macos.log; then
        rollback_bump
    fi
    log "macOS archive complete → v$VERSION build $NEW_BUILD"
fi

# ============================================================
# PHASE 3 — COMMIT & PUSH (after successful archiving)
# ============================================================

log "Committing build $NEW_BUILD..."
git add "$PBXPROJ"
git commit -m "chore: bump build to $NEW_BUILD (v$VERSION)


log "Pushing to remote..."
git push
log "Build $NEW_BUILD committed and pushed"

# ============================================================
# PHASE 4 — UPLOAD TO TESTFLIGHT
# ============================================================

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
        error "iOS upload failed — check /tmp/xcodebuild-ios-export.log"
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
        error "macOS upload failed — check /tmp/xcodebuild-macos-export.log"
    fi
    log "macOS uploaded to App Store Connect"
fi

log "Done! v$VERSION build $NEW_BUILD uploaded to TestFlight"
log "Check App Store Connect → TestFlight for processing status"
