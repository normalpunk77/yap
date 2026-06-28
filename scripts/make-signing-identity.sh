#!/usr/bin/env bash
# Create a stable self-signed code-signing identity named "Yap Self-Signed" in your login
# keychain. build-app.sh prefers it over ad-hoc signing, which gives every local build the
# SAME code signature — so the Keychain (where your API key lives) keeps trusting the app
# across rebuilds instead of re-prompting every time. Run once.
#
# It may ask for your login-keychain password during import — that's macOS, not us.
set -euo pipefail

NAME="Yap Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Identity '$NAME' already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<'CFG'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = Yap Self-Signed
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CFG

# Self-signed cert + key, valid 10 years.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg"

# macOS `security import` can't verify the PKCS#12 MAC that OpenSSL 3 writes by default, so we
# pass -legacy for OpenSSL. But the SYSTEM openssl is LibreSSL, which doesn't support (or need)
# -legacy — passing it there makes the script error out on a clean machine. Add it only for OpenSSL.
LEGACY=""
if ! openssl version | grep -qi libressl; then
    LEGACY="-legacy"
fi
openssl pkcs12 -export $LEGACY -name "$NAME" -passout pass:yap \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12"

# -A lets codesign use the key without a per-build prompt.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P yap -T /usr/bin/codesign -A

security find-identity -p codesigning | grep "$NAME" \
    && echo "Created '$NAME'. Rebuild with: make build" \
    || { echo "Import succeeded but the identity isn't listed — see Keychain Access."; exit 1; }
