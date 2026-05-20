#!/usr/bin/env bash
# Generates a stable self-signed code-signing identity for the CI release
# workflow. Output: base64-encoded PKCS12 + password — paste these into
# the repo's GitHub Actions secrets as RELEASE_P12_BASE64 and RELEASE_P12_PASSWORD.
#
# Run this ONCE. The CI workflow will import the .p12 on every build, so
# every released OpenLark.app.zip has the same code-directory hash. macOS TCC
# keeps mic / accessibility / input-monitoring grants across version updates.
#
# This identity is separate from the local "OpenLark Dev" cert created by
# scripts/setup-signing-identity.sh — the dev cert is per-machine; this one
# is shared by every release artifact.

set -euo pipefail

IDENTITY_NAME="OpenLark Release"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

KEY="$TMP_DIR/key.pem"
CERT="$TMP_DIR/cert.pem"
P12="$TMP_DIR/identity.p12"

# Generate a 32-character random password for the PKCS12.
P12_PW="$(openssl rand -hex 16)"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$KEY" -out "$CERT" -subj "/CN=$IDENTITY_NAME" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# Legacy PKCS12 encryption — required by macOS `security import`.
openssl pkcs12 -export -inkey "$KEY" -in "$CERT" \
    -out "$P12" -passout "pass:$P12_PW" \
    -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

P12_BASE64="$(base64 < "$P12")"

cat <<EOF

✓ Generated stable release signing identity: $IDENTITY_NAME

Add these two secrets to https://github.com/FabianGenell/openlark/settings/secrets/actions

  Name:  RELEASE_P12_PASSWORD
  Value: $P12_PW

  Name:  RELEASE_P12_BASE64
  Value:
$P12_BASE64

If you can use \`gh\`, run these instead:

  gh secret set RELEASE_P12_PASSWORD --body "$P12_PW"
  gh secret set RELEASE_P12_BASE64 --body "$P12_BASE64"

Future runs of the GitHub Actions Release workflow will import this identity
into a temporary keychain and use it to sign OpenLark.app — every release
will share the same code-directory hash, so users keep their macOS
permission grants across updates.
EOF
