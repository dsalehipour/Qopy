#!/usr/bin/env bash
# Creates the local code-signing identity that scripts/build-mac.sh signs with.
#
# macOS pins Accessibility / Camera grants to the app's signature. Ad-hoc signing
# changes every build, so those grants silently lapse. A fixed local certificate
# keeps the signature stable: grant once, keep it.
#
# Self-signed and local only. Run once per machine.
set -euo pipefail

IDENTITY="qopy-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "'$IDENTITY' already exists: nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = qopy-dev
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "==> generating certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

PW="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" \
    -passout "pass:$PW" -name "$IDENTITY" \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null

echo "==> importing into the login keychain"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PW" -A >/dev/null

echo "==> trusting it for code signing (may prompt for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning | grep "\"$IDENTITY\"" || {
    echo "identity was created but is still not valid for code signing" >&2
    exit 1
}
echo
echo "Done. Rebuild with scripts/build-mac.sh, then grant Accessibility / Camera once in"
echo "System Settings → Privacy & Security."
