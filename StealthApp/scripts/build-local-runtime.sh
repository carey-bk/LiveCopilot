#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
python3 "$here/stage-offline-runtime.py" "${1:?pass the build product Contents directory}"
# Xcode removes framework headers when embedding Sparkle. Seal this embedded copy
# after that transformation and before Xcode signs the outer app.
if [[ -d "$1/Frameworks/Sparkle.framework" ]]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$1/Frameworks/Sparkle.framework"
fi
