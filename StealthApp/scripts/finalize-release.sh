#!/bin/bash
# Run only after Apple accepts and stapler staples the final DMG.
set -euo pipefail
[[ $# -eq 1 ]] || { echo 'Usage: finalize-release.sh /path/LiveCopilot-VERSION-macOS-universal.dmg' >&2; exit 1; }
DMG="$1"
NAME="$(basename "$DMG")"
VERSION="${NAME#LiveCopilot-}"
VERSION="${VERSION%-macOS-universal.dmg}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Unexpected DMG filename' >&2; exit 1; }
codesign --verify --strict "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
hdiutil verify "$DMG"
cd "$(dirname "$DMG")"
shasum -a 256 "$NAME" "LiveCopilot-$VERSION-ReleaseInfo.txt" > SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
echo 'Final stapled disk image verified. Publish this exact file and these checksums.'
