#!/bin/bash
# Opt-in real OpenAI calls, synthetic data only. Keychain preferred; never echo the key.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun swiftc -swift-version 5 -parse-as-library \
  Sources/Stealth/Core/*.swift Sources/Stealth/Knowledge/*.swift Sources/Stealth/Providers/*.swift \
  Sources/Stealth/Audio/PCMConverter.swift Sources/Stealth/Support/KeychainStore.swift \
  Tests/IntegrationMain.swift -o build/tests/IntegrationCheck
build/tests/IntegrationCheck "$@"
