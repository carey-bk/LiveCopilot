#!/bin/bash
# ONE-TIME setup: create a stable self-signed code-signing identity so macOS keeps
# the Screen Recording permission across rebuilds (TCC keys the grant to this cert,
# not to the per-build ad-hoc cdhash that changes every time).
#
# Run once:   sudo ./setup-signing.sh
set -euo pipefail
cd "$(dirname "$0")"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo:  sudo ./setup-signing.sh"
  exit 1
fi

# The real user (not root) whose login keychain we target.
REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(eval echo "~$REAL_USER")
LOGIN_KC="$USER_HOME/Library/Keychains/login.keychain-db"

DIR=".signing"
mkdir -p "$DIR"
cd "$DIR"

echo "==> Generating self-signed code-signing certificate…"
cat > cert.conf <<'EOF'
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3_ext
[ dn ]
CN = LiveCopilot Local Signing
[ v3_ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
  -days 3650 -nodes -config cert.conf >/dev/null 2>&1

openssl pkcs12 -export -inkey key.pem -in cert.pem \
  -out signing.p12 -passout pass:stealth -name "LiveCopilot Local Signing" \
  -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

echo "==> Importing into $REAL_USER login keychain…"
# Run the import AS THE USER so key+cert land in their login keychain and link.
sudo -u "$REAL_USER" security import signing.p12 \
  -k "$LOGIN_KC" -P stealth \
  -T /usr/bin/codesign -T /usr/bin/security \
  -A >/dev/null

echo "==> Trusting the certificate for code signing…"
security add-trusted-cert -d -r trustRoot \
  -p codeSign -k /Library/Keychains/System.keychain cert.pem

echo "==> Verifying identity is available…"
if sudo -u "$REAL_USER" security find-identity -v -p codesigning | grep -q "LiveCopilot Local Signing"; then
  echo "✅ Signing identity ready. Now run:  ./run.sh"
else
  echo "⚠️  Identity not found after import. Check Keychain Access for 'LiveCopilot Local Signing'."
  exit 1
fi
