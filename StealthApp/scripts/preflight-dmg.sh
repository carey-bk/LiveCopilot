#!/bin/bash
# Local pre-notarization packaging rehearsal. Requires an isolated, signed Release app.
set -euo pipefail
cd "$(dirname "$0")/../.."
app="${1:?Pass a staged signed app}"
out="${2:?Pass an unused temporary output directory}"
identity="${3:?Developer ID Application identity}"
mkdir "$out"
stage="$(mktemp -d "$out/stage.XXXXXX")"
image="$out/LiveCopilot-$(python3 StealthApp/scripts/release-version.py)-macOS-universal.dmg"
python3 -B StealthApp/scripts/sign-distribution.py "$app" --verify-only
ditto --noextattr --norsrc "$app" "$stage/LiveCopilot.app"
cp LICENSE "$stage/LICENSE.txt"
cp docs/INSTALL.txt "$stage/Install - 安装说明.txt"
echo "Local pre-notarization validation" > "$stage/ReleaseInfo.txt"
swift StealthApp/scripts/dmg/artwork.swift "$stage"
"${DMGBUILD_BIN:-dmgbuild}" -s StealthApp/scripts/dmg/settings.py -D "stage=$stage" "LiveCopilot" "$image"
codesign --sign "$identity" --timestamp "$image"
codesign --verify --strict "$image"
hdiutil verify "$image"
mount="$(mktemp -d "$out/mount.XXXXXX")"
hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$image"
trap 'hdiutil detach "$mount" >/dev/null' EXIT
python3 -B StealthApp/scripts/sign-distribution.py "$mount/LiveCopilot.app" --verify-only
python3 StealthApp/scripts/verify-bundled-weights.py "$mount/LiveCopilot.app"
