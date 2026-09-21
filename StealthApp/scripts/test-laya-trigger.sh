#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests/module-cache
xcrun swiftc -swift-version 5 -parse-as-library -g \
  -target "$(uname -m)-apple-macosx14.0" -module-cache-path build/tests/module-cache \
  Sources/Stealth/Core/*.swift Sources/Stealth/Knowledge/*.swift Sources/Stealth/Providers/*.swift \
  Tests/LayaTriggerChecks.swift -o build/tests/LayaTriggerChecks
build/tests/LayaTriggerChecks
