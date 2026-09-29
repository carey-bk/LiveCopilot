#!/bin/bash
# Build a standalone preview that never reads real credentials or captures audio.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/prepare-sparkle.sh
XCODEGEN_BIN="${XCODEGEN_BIN:-$(command -v xcodegen || true)}"
if [[ -z "$XCODEGEN_BIN" && -x "$HOME/.local/bin/xcodegen" ]]; then XCODEGEN_BIN="$HOME/.local/bin/xcodegen"; fi
if [[ -z "$XCODEGEN_BIN" ]]; then echo "XcodeGen is required." >&2; exit 1; fi
if [[ ! -d Resources/LocalRuntime ]]; then ./scripts/build-local-runtime.sh; fi
mkdir -p build
"$XCODEGEN_BIN" generate
xcodebuild -project LiveCopilot.xcodeproj -scheme LiveCopilot -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build > build/onboarding-build.log 2>&1
mkdir -p "build/Onboarding/LiveCopilot Preview.app"
rsync -a "build/Build/Products/Debug/LiveCopilot.app/" "build/Onboarding/LiveCopilot Preview.app/"
python3 - <<'PY'
import pathlib, plistlib
target = pathlib.Path('build/Onboarding/LiveCopilot Preview.app')
path = target / 'Contents/Info.plist'
with path.open('rb') as stream:
    info = plistlib.load(stream)
info.update(CFBundleIdentifier='com.livecopilot.onboarding-preview',
            CFBundleName='LiveCopilot Preview', CFBundleDisplayName='LiveCopilot Preview',
            LiveCopilotOnboardingPreview=True)
with path.open('wb') as stream:
    plistlib.dump(info, stream)
print(target.resolve())
PY
codesign --force --deep --sign - "build/Onboarding/LiveCopilot Preview.app"
open -n "build/Onboarding/LiveCopilot Preview.app" --args --mock --onboarding-preview --ui-preview "$@"
