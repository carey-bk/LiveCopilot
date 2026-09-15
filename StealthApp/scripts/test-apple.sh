#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun swiftc -swift-version 5 -parse-as-library -O \
 Sources/Stealth/Core/*.swift Sources/Stealth/Providers/*.swift Sources/Stealth/Knowledge/*.swift Sources/Stealth/Audio/PCMConverter.swift \
 Tests/AppleIntegrationMain.swift -o build/tests/AppleChecks
build/tests/AppleChecks "${1:?Pass a directory with en.aiff, zh.aiff, own.aiff synthetic fixtures}"
