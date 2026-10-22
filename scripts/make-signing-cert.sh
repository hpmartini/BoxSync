#!/bin/bash
# One-time setup: self-signed code-signing certificate "BoxSync Local Signing" in the login keychain.
# A stable signature keeps the app identity the same across rebuilds, so macOS stops asking for the
# keychain password after every build. Remove again: security delete-identity -c "BoxSync Local Signing"
set -euo pipefail
NAME="BoxSync Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "$NAME"; then
    echo "Certificate \"$NAME\" already exists, nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OPENSSL=/usr/bin/openssl   # macOS-bundled LibreSSL: newer OpenSSL writes PKCS12 that `security import` rejects
PASS="$($OPENSSL rand -hex 16)"

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

$OPENSSL req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/openssl.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
$OPENSSL pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -passout "pass:$PASS" -out "$TMP/id.p12"

# -T: only codesign may use the private key without a prompt
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
# Trust for code signing, current user only (macOS asks for your login password once)
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

security find-identity -v -p codesigning "$KEYCHAIN" | grep "$NAME"
