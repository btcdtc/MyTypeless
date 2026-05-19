#!/usr/bin/env bash
# Vendor llama-server + its peer dylibs into ./vendor/, rewriting build-time
# rpaths so the bundled binary resolves its dylibs from the same directory
# (Contents/Resources/llama/) at runtime.
#
# Usage:
#   scripts/vendor-llama.sh <path-to-llama.cpp/build/bin>
#
# Re-run any time llama.cpp is rebuilt.
set -euo pipefail

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
    echo "usage: $0 <path-to-llama.cpp/build/bin>" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"

mkdir -p "$VENDOR"
rm -f "$VENDOR/llama-server-arm64" "$VENDOR"/*.dylib

[ -x "$SRC/llama-server" ] || { echo "missing $SRC/llama-server" >&2; exit 1; }
cp "$SRC/llama-server" "$VENDOR/llama-server-arm64"

for dy in "$SRC"/*.dylib; do
    [ -e "$dy" ] || continue
    cp "$dy" "$VENDOR/"
done

is_system_dep() {
    local dep="$1"
    [[ "$dep" == /usr/lib/* || "$dep" == /System/Library/* ]]
}

is_relative_dep() {
    local dep="$1"
    [[ "$dep" == @rpath/* || "$dep" == @loader_path/* || "$dep" == @executable_path/* ]]
}

copy_non_system_deps() {
    local queue=("$VENDOR/llama-server-arm64")
    for dy in "$VENDOR"/*.dylib; do
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
            if [ ! -f "$VENDOR/$base" ]; then
                cp "$dep" "$VENDOR/$base"
                queue+=("$VENDOR/$base")
            fi
        done < <(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}')
    done
}

# Strip every existing LC_RPATH and add @loader_path so peers resolve from
# the same directory as the loading binary at runtime.
strip_rpaths_to_loader_path() {
    local file="$1"
    # `otool -l` lists LC_RPATH commands; the rpath value is on the line after.
    while read -r rp; do
        [ -z "$rp" ] && continue
        install_name_tool -delete_rpath "$rp" "$file" 2>/dev/null || true
    done < <(otool -l "$file" 2>/dev/null | awk '/LC_RPATH/{getline; getline; print $2}')
    install_name_tool -add_rpath "@loader_path" "$file" 2>/dev/null || true
}

normalize_install_names() {
    local file="$1"
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
        [ -f "$VENDOR/$dep_base" ] || continue
        install_name_tool -change "$dep" "@rpath/$dep_base" "$file" 2>/dev/null || true
    done < <(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}')
}

copy_non_system_deps

strip_rpaths_to_loader_path "$VENDOR/llama-server-arm64"
normalize_install_names "$VENDOR/llama-server-arm64"
for dy in "$VENDOR"/*.dylib; do
    [ -e "$dy" ] || continue
    strip_rpaths_to_loader_path "$dy"
    normalize_install_names "$dy"
done

echo "vendored to $VENDOR:"
ls -1 "$VENDOR"
