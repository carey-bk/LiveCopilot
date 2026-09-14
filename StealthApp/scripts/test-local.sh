#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun swiftc -swift-version 5 -parse-as-library -O \
  Sources/Stealth/Core/*.swift Sources/Stealth/Knowledge/*.swift Sources/Stealth/Providers/*.swift \
  Sources/Stealth/Audio/PCMConverter.swift Tests/LocalIntegrationMain.swift -o build/tests/LocalChecks
build/tests/LocalChecks "$@"
