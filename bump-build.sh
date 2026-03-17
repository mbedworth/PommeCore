#!/bin/bash
# bump-build.sh — increments build number across all targets
# Usage: ./bump-build.sh

PBXPROJ="MeshCoreApple.xcodeproj/project.pbxproj"

# Get current build number
CURRENT=$(grep -m1 "CURRENT_PROJECT_VERSION" "$PBXPROJ" | grep -o '[0-9]*' | head -1)
NEW=$((CURRENT + 1))

# Replace ALL instances
sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT;/CURRENT_PROJECT_VERSION = $NEW;/g" "$PBXPROJ"

echo "Build number: $CURRENT → $NEW"
