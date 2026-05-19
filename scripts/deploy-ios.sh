#!/usr/bin/env bash
# Build the iOS host app + keyboard extension and install on a connected
# iPhone via devicectl. Auto-picks the first available iOS device unless
# DEVICE_ID is set.
#
# Defaults to Release because Debug builds in modern Xcode emit a stub
# executable plus `.debug.dylib`, and iOS's keyboard daemon won't load the
# dylib without a debugger attached — the on-device keyboard then silently
# falls back to the previously installed version. Release embeds everything
# in the main binary so the OS can load it standalone.
#
# Usage:
#   scripts/deploy-ios.sh                     # Release build + install
#   scripts/deploy-ios.sh launch              # + launch (phone must be unlocked)
#   CONFIG=Debug scripts/deploy-ios.sh        # only useful when Xcode runs it
#   TEAM=... DEVICE_ID=... scripts/deploy-ios.sh  # TEAM is an explicit override
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/iOS/TypeformeIOS.xcodeproj"
SCHEME="TypeformeIOS"
BUNDLE_ID="com.btcdtc.typeforme"
CONFIG="${CONFIG:-Release}"
DERIVED="${DERIVED:-/tmp/TypeformeIOS-DD-${CONFIG}}"
TEAM="${TEAM:-}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -d "$DEVELOPER_DIR" ]; then
    echo "Xcode not found at $DEVELOPER_DIR. Set DEVELOPER_DIR explicitly." >&2
    exit 1
fi

ACTION="${1:-install}"

if [ -z "${DEVICE_ID:-}" ]; then
    # Accept any state that isn't `unavailable` — devicectl reports either
    # "available (paired)" when the device is sleeping or "connected" when
    # actively attached. Both are fine for install.
    DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null \
        | awk 'NR>2 && $0 ~ /iPhone/ && $0 !~ /unavailable/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{36}$/) { print $i; exit } }')"
fi
if [ -z "$DEVICE_ID" ]; then
    echo "No paired iPhone found. Connect via cable or set DEVICE_ID." >&2
    xcrun devicectl list devices >&2 || true
    exit 1
fi

echo "→ Building Typeforme iOS ($CONFIG) for device $DEVICE_ID"
BUILD_ARGS=()
if [ -n "$TEAM" ]; then
    echo "→ Overriding project DEVELOPMENT_TEAM with TEAM=$TEAM"
    BUILD_ARGS+=(DEVELOPMENT_TEAM="$TEAM")
fi

XCODEBUILD_ARGS=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -destination "id=$DEVICE_ID"
    -configuration "$CONFIG"
    -allowProvisioningUpdates
    -derivedDataPath "$DERIVED"
)
if [ "${#BUILD_ARGS[@]}" -gt 0 ]; then
    XCODEBUILD_ARGS+=("${BUILD_ARGS[@]}")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" build

APP_PRODUCTS_DIR="$DERIVED/Build/Products/${CONFIG}-iphoneos"
APP_PATH="$APP_PRODUCTS_DIR/Typeforme.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Built app not found at $APP_PATH" >&2
    exit 1
fi

echo "→ Installing $APP_PATH"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

if [ "$ACTION" = "launch" ]; then
    echo "→ Launching $BUNDLE_ID"
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" || {
        echo "Launch failed — unlock the device and tap the app icon." >&2
        exit 1
    }
fi

echo "✔ Deployed."
