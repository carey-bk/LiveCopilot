#!/bin/bash
# Build, sign, install to a STABLE location, and launch Stealth.
#
# Signing: if the "Stealth Local Signing" identity exists (run setup-signing.sh once),
# we sign with it so macOS keeps the Screen Recording grant across rebuilds.
# Otherwise we fall back to ad-hoc (grant will need re-approving after code changes).
set -euo pipefail
cd "$(dirname "$0")"

# Stamp a fresh build number (YYYYMMDD.HHMM) so the UI shows whether the
# running app reflects the latest code.
BUILD_NUMBER="$(date +%Y%m%d.%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" Resources/Info.plist
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
echo "Build: v$VERSION ($BUILD_NUMBER)"

/opt/homebrew/bin/xcodegen generate >/dev/null
# Release config: links into a single binary (no separate Stealth.debug.dylib,
# which otherwise breaks re-signing with a custom identity).
xcodebuild -project Stealth.xcodeproj -scheme Stealth -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build >/dev/null

BUILT="build/Build/Products/Release/Stealth.app"
DEST="/Applications/Stealth.app"

# Pick a stable identity if available, else ad-hoc.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Stealth Local Signing"; then
  SIGN_ID="Stealth Local Signing"
  echo "Signing with stable identity: $SIGN_ID"
else
  SIGN_ID="-"
  echo "Signing ad-hoc (run 'sudo ./setup-signing.sh' once for a stable, permission-persisting identity)."
fi

# Install to the stable /Applications path so the code path never changes.
echo "Installing to $DEST"
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"

# Sign inside-out: any nested dylibs/frameworks first, then the app bundle.
find "$DEST/Contents" \( -name "*.dylib" -o -name "*.framework" \) -print0 2>/dev/null \
  | while IFS= read -r -d '' item; do
      codesign --force --sign "$SIGN_ID" "$item"
    done
codesign --force --sign "$SIGN_ID" \
  --entitlements Resources/Stealth.entitlements "$DEST"

# Restart any running instance.
pkill -x Stealth 2>/dev/null || true
sleep 1

echo "Launching $DEST"
open "$DEST"
echo "Look for the waveform icon in your menu bar (top-right). No dock icon by design."
