#!/bin/bash
#
# meshctl.sh — build and run the meshctl hardware harness.
#
# Why this is more than `swift run meshctl`:
#
# CoreBluetooth aborts the process (SIGABRT, TCC) unless it can read
# NSBluetoothAlwaysUsageDescription from an Info.plist. Two things are needed,
# both established the hard way on macOS 27:
#
#   1. A real app bundle. Embedding the plist in the Mach-O __TEXT,__info_plist
#      section is enough for some TCC services but not Bluetooth — the section was
#      verifiably present and the binary ad-hoc signed, and TCC still reported
#      "no usage description" and aborted.
#   2. Launching via `open`, not directly. Run from a shell, TCC attributes the
#      request to the responsible process — the terminal — which has no Bluetooth
#      usage description, so it aborts regardless of our own plist. `open` makes
#      launchd the parent, so the app is its own responsible process.
#
# `open` detaches stdout, so the tool mirrors its output to a report file which
# this script prints, and carries its exit status on the last line.
#
# The first run raises a one-time Bluetooth permission prompt that must be
# accepted; the grant is remembered for the bundle identifier afterwards.
#
# Usage:  ./scripts/meshctl.sh <command> [options]
#         ./scripts/meshctl.sh scan
#         ./scripts/meshctl.sh smoke --target a1b2c3
#
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../Packages/MeshCoreKit" && pwd)"
PLIST="$PKG_DIR/Sources/meshctl/Info.plist"
APP="$PKG_DIR/.build/meshctl.app"
REPORT="$(mktemp /tmp/meshctl-report.XXXXXX)"

cd "$PKG_DIR"

swift build --product meshctl >/dev/null
BIN="$(swift build --product meshctl --show-bin-path)/meshctl"

mkdir -p "$APP/Contents/MacOS"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/meshctl"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# -W waits for exit, -n forces a fresh instance so repeated runs do not reattach.
open -W -n -a "$APP" --args "$@" --report "$REPORT" || true

if [[ ! -s "$REPORT" ]]; then
    echo "meshctl produced no output — it most likely aborted before starting." >&2
    echo "Check Bluetooth permission: System Settings → Privacy & Security → Bluetooth." >&2
    rm -f "$REPORT"
    exit 70
fi

grep -v '^meshctl-exit:' "$REPORT" || true

STATUS="$(grep '^meshctl-exit:' "$REPORT" | tail -1 | awk '{print $2}')"
rm -f "$REPORT"
exit "${STATUS:-70}"
