#!/usr/bin/env bash
# Create a self-signed code-signing identity called "Typeforme Local Dev" in
# the login keychain. Once this exists, build-app.sh will pick it up
# automatically and every rebuild of dist/Typeforme.app gets the same
# signature. macOS's TCC keys permission grants by signature, so this means
# the Accessibility / Microphone grants you give Typeforme persist across
# Xcode rebuilds.
#
# Run once per machine:
#   scripts/create-signing-identity.sh
# Then rebuild:
#   ./scripts/build-app.sh release
set -euo pipefail

IDENTITY="Typeforme Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v "$KEYCHAIN" 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "Identity '$IDENTITY' already valid in login keychain. Done."
    exit 0
fi

# Use system openssl (LibreSSL). Apple's `security` tool can't read PKCS#12
# files produced by Homebrew OpenSSL 3.x with the modern defaults.
OPENSSL=/usr/bin/openssl

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

# X.509 extensions for code signing on macOS — needs BOTH the basic
# `keyUsage = digitalSignature` AND `extendedKeyUsage = codeSigning`,
# otherwise the keychain accepts the cert but find-identity reports
# "Invalid Key Usage for policy" and codesign refuses to use it.
cat > openssl.cnf <<EOF
[req]
distinguished_name   = dn
x509_extensions      = ext
prompt               = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints     = CA:false
keyUsage             = digitalSignature
extendedKeyUsage     = codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 36500 \
    -keyout key.pem -out cert.pem -config openssl.cnf >/dev/null 2>&1

# Apple's `security import` wants SHA1 MAC + non-empty password.
"$OPENSSL" pkcs12 -export -inkey key.pem -in cert.pem -out cert.p12 \
    -name "$IDENTITY" -passout pass:typeforme -macalg SHA1 >/dev/null

# -T whitelists codesign + security to use the private key without an
# access dialog every time. The keychain itself may pop up once to ask
# you to authorize the import.
security import cert.p12 \
    -k "$KEYCHAIN" \
    -P typeforme \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

# Trust as a code-signing root in the user trust store (no admin needed).
# Without this the cert imports but find-identity reports CSSMERR_TP_NOT_TRUSTED.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem >/dev/null

echo "✓ Created '$IDENTITY' in login keychain (trusted for code signing)."
security find-identity -p codesigning -v "$KEYCHAIN" 2>/dev/null | grep "$IDENTITY" || true
echo
echo "Next: rebuild the .app so it gets signed with the stable identity:"
echo "  ./scripts/build-app.sh release"
echo
echo "Then in Typeforme Settings → General → Permissions:"
echo "  1. Click \"Reset & re-prompt\" once (clears any stale TCC entry)"
echo "  2. Toggle Typeforme on in System Settings → Privacy → Accessibility"
echo "  3. From here on the grant persists across rebuilds."
