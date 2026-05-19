#!/usr/bin/env bash
# Build dist/Typeforme.app from the Xcode-built package executable, including
# AppIcon and bundled helper binaries when present.
#
# Usage:
#   scripts/build-app.sh [debug|release]      # default: debug
#   IDENTITY="Developer ID Application: ..." scripts/build-app.sh release
#
# Adhoc signing (default) is fine for local-only use on this machine.
# Pass IDENTITY=... to sign for distribution / notarization.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Typeforme"
BINARY_NAME="Typeforme"
SCHEME="Typeforme"
APP_DIR="$ROOT/dist/${APP_NAME}.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
LLAMA_DIR="$RES_DIR/llama"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

XCODEBUILD="${DEVELOPER_DIR:-}/usr/bin/xcodebuild"
if [ ! -x "$XCODEBUILD" ]; then
    cat >&2 <<'EOF'
error: full Xcode is required to build Typeforme.

Set DEVELOPER_DIR to Xcode, for example:
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

Use the Xcode-backed scripts for project verification.
EOF
    exit 2
fi

case "$CONFIG" in
    debug|release) ;;
    *) echo "config must be debug|release, got: $CONFIG" >&2; exit 1 ;;
esac

is_system_dep() {
    local dep="$1"
    [[ "$dep" == /usr/lib/* || "$dep" == /System/Library/* ]]
}

is_relative_dep() {
    local dep="$1"
    [[ "$dep" == @rpath/* || "$dep" == @loader_path/* || "$dep" == @executable_path/* ]]
}

strip_rpaths_to_loader_path() {
    local file="$1"
    while read -r rp; do
        [ -z "$rp" ] && continue
        install_name_tool -delete_rpath "$rp" "$file" 2>/dev/null || true
    done < <(otool -l "$file" 2>/dev/null | awk '/LC_RPATH/{getline; getline; print $2}')
    install_name_tool -add_rpath "@loader_path" "$file" 2>/dev/null || true
}

normalize_install_names() {
    local file="$1"
    local dir="$2"
    local base
    base="$(basename "$file")"
    if [[ "$file" == *.dylib ]]; then
        install_name_tool -id "@rpath/$base" "$file" 2>/dev/null || true
    fi

    while read -r dep; do
        [ -n "$dep" ] || continue
        is_system_dep "$dep" && continue
        local dep_base
        dep_base="$(basename "$dep")"
        [ -f "$dir/$dep_base" ] || continue
        install_name_tool -change "$dep" "@rpath/$dep_base" "$file" 2>/dev/null || true
    done < <(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}')
}

bundle_non_system_deps() {
    local dir="$1"
    local main_binary="$2"
    local queue=("$dir/$main_binary")
    for dy in "$dir"/*.dylib; do
        [ -e "$dy" ] && queue+=("$dy")
    done

    local i=0
    while [ "$i" -lt "${#queue[@]}" ]; do
        local file="${queue[$i]}"
        i=$((i + 1))
        while read -r dep; do
            [ -n "$dep" ] || continue
            is_relative_dep "$dep" && continue
            is_system_dep "$dep" && continue
            if [ ! -f "$dep" ]; then
                echo "warn: non-system dylib not found: $dep (needed by $(basename "$file"))" >&2
                continue
            fi
            local base
            base="$(basename "$dep")"
            if [ ! -f "$dir/$base" ]; then
                cp "$dep" "$dir/$base"
                queue+=("$dir/$base")
            fi
        done < <(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}')
    done

    strip_rpaths_to_loader_path "$dir/$main_binary"
    normalize_install_names "$dir/$main_binary" "$dir"
    for dy in "$dir"/*.dylib; do
        [ -e "$dy" ] || continue
        strip_rpaths_to_loader_path "$dy"
        normalize_install_names "$dy" "$dir"
    done
}

cd "$ROOT"

XCODE_CONFIG="Debug"
if [ "$CONFIG" = "release" ]; then
    XCODE_CONFIG="Release"
fi

XCODE_DERIVED="$ROOT/.build/xcode-derived"
"$XCODEBUILD" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS,arch=arm64' \
    -configuration "$XCODE_CONFIG" \
    -derivedDataPath "$XCODE_DERIVED" \
    build
BIN_SRC="$XCODE_DERIVED/Build/Products/$XCODE_CONFIG/$BINARY_NAME"
[ -x "$BIN_SRC" ] || { echo "built binary not found" >&2; exit 1; }
PRODUCT_DIR="$(cd "$(dirname "$BIN_SRC")" && pwd)"

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR" "$LLAMA_DIR"

cp "$BIN_SRC" "$BIN_DIR/${BINARY_NAME}"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# SwiftPM dependencies can generate resource bundles even when they are linked
# statically. KeyboardShortcuts uses this for localized UI strings; omitting it
# makes NSBundle.module trap when the shortcut recorder is rendered.
for bundle in "$PRODUCT_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$RES_DIR/"
done

# App icon — render via scripts/generate-icon.swift if missing, then iconutil.
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    if [ -d "$ROOT/Resources/AppIcon.iconset" ]; then
        iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
    else
        echo "warn: AppIcon.icns missing and no iconset to compile — bundle will have no icon" >&2
    fi
fi
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"

# Bundled llama-server (optional). When present, codesign with the
# llama-server entitlements (allow-jit) so it can JIT Metal kernels.
# Prefer the stable local development identity created by
# scripts/create-signing-identity.sh so TCC permission grants survive rebuilds.
# Public builds can still override this with IDENTITY="Developer ID ..."; pass
# IDENTITY="-" explicitly for ad-hoc signing.
SIGN_IDENTITY="${IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    if security find-identity -p codesigning -v 2>/dev/null | grep -q '"Typeforme Local Dev"'; then
        SIGN_IDENTITY="Typeforme Local Dev"
    else
        SIGN_IDENTITY="-"
    fi
fi
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "signing identity: adhoc"
else
    echo "signing identity: configured via IDENTITY"
fi
LLAMA_ENT="$ROOT/Resources/llama-server.entitlements"
LLAMA_SRC="$ROOT/vendor/llama-server-arm64"
if [ -x "$LLAMA_SRC" ]; then
    cp "$LLAMA_SRC" "$LLAMA_DIR/llama-server-arm64"
    chmod +x "$LLAMA_DIR/llama-server-arm64"
    # Bring along any sibling dylibs / metallib shipped next to the binary.
    for sib in "$ROOT"/vendor/*.dylib "$ROOT"/vendor/*.metallib; do
        [ -e "$sib" ] && cp "$sib" "$LLAMA_DIR/"
    done
    bundle_non_system_deps "$LLAMA_DIR" "llama-server-arm64"
    # Sign the helper FIRST (deepest first), then the app bundle below.
    codesign --force --options runtime --entitlements "$LLAMA_ENT" \
             --sign "$SIGN_IDENTITY" "$LLAMA_DIR/llama-server-arm64" \
        || echo "warn: llama-server codesign failed" >&2
    for sib in "$LLAMA_DIR"/*.dylib "$LLAMA_DIR"/*.metallib; do
        [ -e "$sib" ] || continue
        codesign --force --options runtime --sign "$SIGN_IDENTITY" "$sib" \
            || echo "warn: codesign $(basename "$sib") failed" >&2
    done
fi

# Sign the app bundle. --deep so anything inside Resources/ is verified too.
APP_ENT="$ROOT/Resources/Typeforme.entitlements"
codesign --force --options runtime --entitlements "$APP_ENT" \
         --sign "$SIGN_IDENTITY" --deep "$APP_DIR" \
    || echo "warn: app codesign failed" >&2

# Sanity check
codesign --verify --deep --strict --verbose=1 "$APP_DIR" 2>&1 | sed 's/^/verify: /' || true

echo "built: $APP_DIR"
if [ -x "$LLAMA_DIR/llama-server-arm64" ]; then
    echo "       (with llama-server-arm64)"
else
    echo "       (no llama-server-arm64 — drop one in vendor/ and rebuild for embedded LLM)"
fi
