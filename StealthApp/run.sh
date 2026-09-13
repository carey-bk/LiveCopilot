#!/bin/bash
# Native build + signed, stable per-user install. No API key is required to build.
set -euo pipefail
cd "$(dirname "$0")"
./scripts/build.sh
BUILT="build/Build/Products/Release/LiveCopilot.app"
DEST="$HOME/Applications/LiveCopilot.app"
mkdir -p "$HOME/Applications"
SIGN_ID="${LIVECOPILOT_SIGNING_IDENTITY:--}"
if security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -q 'LiveCopilot Local Signing'; then SIGN_ID='LiveCopilot Local Signing'; fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M%S)" "$BUILT/Contents/Info.plist"
codesign --force --sign "$SIGN_ID" --entitlements Resources/LiveCopilot.entitlements "$BUILT"
codesign --verify --deep --strict "$BUILT"
if pgrep -x -u "$USER" LiveCopilot >/dev/null; then
    pkill -TERM -x -u "$USER" LiveCopilot
    for _ in {1..120}; do
      if ! pgrep -x -u "$USER" LiveCopilot >/dev/null; then break; fi
      sleep 0.1
    done
    if pgrep -x -u "$USER" LiveCopilot >/dev/null; then
      echo "LiveCopilot is still closing. Quit it and rerun to install safely." >&2; exit 1
    fi
fi
if [[ -d "$DEST" ]]; then
  mv "$DEST" "$DEST.previous.$(date +%Y%m%d%H%M%S)"
fi
cp -R "$BUILT" "$DEST"
echo "Installed: $DEST"
open "$DEST" --args "$@"
