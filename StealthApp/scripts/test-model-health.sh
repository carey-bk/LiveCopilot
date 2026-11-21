#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 2 ]]; then
  echo 'Usage: test-model-health.sh <verified-arctic-model-directory> <native-worker>' >&2
  exit 2
fi
mkdir -p build/tests
xcrun swiftc -swift-version 5 -parse-as-library -O \
  Sources/Stealth/Core/*.swift Sources/Stealth/Knowledge/*.swift Sources/Stealth/Providers/*.swift \
  Sources/Stealth/Stores/LocalModelManager.swift Tests/ModelHealthMain.swift -o build/tests/ModelHealth
build/tests/ModelHealth "$1" "$2"
