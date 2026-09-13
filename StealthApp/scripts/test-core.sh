#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun swiftc -swift-version 5 -parse-as-library -g \
  Sources/Stealth/Core/*.swift Sources/Stealth/Knowledge/*.swift Sources/Stealth/Providers/*.swift \
  Tests/CoreChecks.swift Tests/TestMain.swift -o build/tests/CoreChecks
build/tests/CoreChecks
