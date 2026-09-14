#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-local-runtime.sh
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Install/open full Xcode and select it with xcode-select before building." >&2; exit 1
fi
XCODEGEN_BIN="${XCODEGEN_BIN:-$(command -v xcodegen || true)}"
if [[ -z "$XCODEGEN_BIN" && -x "$HOME/.local/bin/xcodegen" ]]; then XCODEGEN_BIN="$HOME/.local/bin/xcodegen"; fi
if [[ -z "$XCODEGEN_BIN" ]]; then echo "Install XcodeGen: brew install xcodegen (or set XCODEGEN_BIN)." >&2; exit 1; fi
"$XCODEGEN_BIN" generate
xcodebuild -project LiveCopilot.xcodeproj -scheme LiveCopilot -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
