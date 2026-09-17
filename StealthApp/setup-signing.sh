#!/bin/bash
# Read-only replacement for the inherited self-signed certificate setup.
set -euo pipefail
echo 'Use a Developer ID Application certificate from your Apple Developer account.'
echo 'This command does not create certificates, export private keys, or change trust/ACLs.'
security find-identity -v -p codesigning
echo 'See docs/RELEASING.md for staging, notarization, and distribution steps.'
