#!/usr/bin/env bash
# Create a stable self-signed code signing identity in the user's login keychain.
# Once installed, all future builds are signed with this fixed identity so macOS
# TCC will preserve mic / accessibility / input-monitoring grants across rebuilds
# (instead of resetting them every time the binary hash changes).
#
# Idempotent: skips creation if the identity is already a valid codesigning identity.
#
# Identity name: "OpenLark Dev"

set -euo pipefail

IDENTITY_NAME="OpenLark Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "✓ signing identity '$IDENTITY_NAME' already exists"
    exit 0
fi

echo "› creating self-signed code signing identity '$IDENTITY_NAME'"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

KEY="$TMP_DIR/key.pem"
CERT="$TMP_DIR/cert.pem"
P12="$TMP_DIR/identity.p12"

# Create self-signed cert with codeSigning extended key usage.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$KEY" -out "$CERT" -subj "/CN=$IDENTITY_NAME" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# macOS `security import` needs legacy PKCS12 encryption.
openssl pkcs12 -export -inkey "$KEY" -in "$CERT" \
    -out "$P12" -passout pass:t \
    -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

# Pre-authorise codesign (no -A so we don't open the key to every app on the
# machine). The user may see one keychain prompt the first time codesign uses it.
security import "$P12" -k "$KEYCHAIN" -P t -T /usr/bin/codesign 2>&1 | grep -v "MAC" || true

# Mark the cert as trusted for codesigning at the user level (no sudo needed).
# Without this step, `security find-identity -p codesigning` skips the cert
# because self-signed certs aren't trusted for codesigning by default.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$CERT" 2>/dev/null || true

if security find-identity -p codesigning -v 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "✓ identity '$IDENTITY_NAME' is ready"
else
    echo "✗ identity import failed, falling back to ad-hoc signing"
    exit 1
fi
