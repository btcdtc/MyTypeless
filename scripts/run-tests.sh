#!/usr/bin/env bash
# Run the macOS test suite through the project Xcode scheme.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

XCODEBUILD="${DEVELOPER_DIR:-}/usr/bin/xcodebuild"
if [ ! -x "$XCODEBUILD" ]; then
    cat >&2 <<'EOF'
error: full Xcode is required to test Typeforme.

Set DEVELOPER_DIR to Xcode, for example:
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

Use the Xcode-backed scripts for project verification.
EOF
    exit 2
fi

exec "$XCODEBUILD" \
    -scheme Typeforme \
    -destination 'platform=macOS,arch=arm64' \
    -configuration Debug \
    -derivedDataPath "$ROOT/.build/xcode-derived" \
    test \
    "$@"
