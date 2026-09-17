#!/bin/bash
# Package a notarized app from a clean release checkout, preserving its signature.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO_DIR="$PWD"
APP_PATH=""
APP_SOURCE_REF=""
OUTPUT_DIR="$REPO_DIR/dist"
SIGN_IDENTITY=""

usage() {
  echo "Usage: $0 --app /path/LiveCopilot.app --app-source-ref COMMIT --sign-identity ID [--output /path/dist]"
  echo "Requires a Developer ID signed, notarized and stapled app. Submit/staple the resulting signed DMG before publication."
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app|--app-source-ref|--output|--sign-identity)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 1; }
      case "$1" in
        --app) APP_PATH="$2" ;;
        --app-source-ref) APP_SOURCE_REF="$2" ;;
        --output) OUTPUT_DIR="$2" ;;
        --sign-identity) SIGN_IDENTITY="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

[[ -z "$(git status --porcelain)" ]] || {
  echo "Commit source and packaging changes before creating a release." >&2; exit 1;
}
RELEASE_COMMIT="$(git rev-parse HEAD)"
[[ -n "$APP_PATH" && -n "$APP_SOURCE_REF" && -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != '-' ]] || { usage >&2; exit 1; }
APP_SOURCE_REF="$(git rev-parse --verify "$APP_SOURCE_REF^{commit}")"
git diff --quiet "$APP_SOURCE_REF" "$RELEASE_COMMIT" -- \
  StealthApp/Sources StealthApp/Resources StealthApp/Native StealthApp/scripts/build-local-runtime.sh StealthApp/project.yml || {
  echo "App inputs changed since --app-source-ref. Build a new app instead." >&2; exit 1;
}
python3 StealthApp/scripts/sign-distribution.py "$APP_PATH" --verify-only
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
[[ -f "$APP_PATH/Contents/Info.plist" ]] || { echo "App bundle not found." >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/livecopilot-dmg.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
ditto --noextattr --norsrc "$APP_PATH" "$STAGE_DIR/LiveCopilot.app"
STAGED_APP="$STAGE_DIR/LiveCopilot.app"
codesign --verify --deep --strict "$STAGED_APP"
xcrun stapler validate "$STAGED_APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED_APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$STAGED_APP/Contents/Info.plist")"
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$STAGED_APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release version." >&2; exit 1; }
EXECUTABLE="$STAGED_APP/Contents/MacOS/LiveCopilot"
ARCHITECTURES="$(lipo -archs "$EXECUTABLE")"
[[ " $ARCHITECTURES " == *" arm64 "* && " $ARCHITECTURES " == *" x86_64 "* ]] || {
  echo "Release must contain both arm64 and x86_64." >&2; exit 1;
}
APP_SHA256="$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')"
SIGNATURE="$(codesign -dv "$STAGED_APP" 2>&1 | sed -n 's/^Authority=Developer ID Application:/Developer ID Application:/p')"
TEAM="$(codesign -dv "$STAGED_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
DMG_NAME="LiveCopilot-$VERSION-macOS-universal.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
[[ ! -e "$DMG_PATH" ]] || { echo "Refusing to overwrite existing release: $DMG_PATH" >&2; exit 1; }

ln -s /Applications "$STAGE_DIR/Applications"
cp LICENSE "$STAGE_DIR/LICENSE.txt"
cp docs/INSTALL.txt "$STAGE_DIR/Install - 安装说明.txt"
cat > "$STAGE_DIR/ReleaseInfo.txt" <<EOF
LiveCopilot $VERSION
Build: $BUILD
Minimum macOS: $MINIMUM_MACOS
Architectures: $ARCHITECTURES
Application source commit: $APP_SOURCE_REF
Release source commit: $RELEASE_COMMIT
Executable SHA-256: $APP_SHA256
Signature: $SIGNATURE
Team ID: $TEAM
Application notarization: Apple ticket stapled and validated; Gatekeeper accepted.
Distribution: validate the disk image's own ticket with xcrun stapler validate.
EOF

hdiutil create -volname "LiveCopilot $VERSION" -srcfolder "$STAGE_DIR" \
  -fs HFS+ -format UDZO "$DMG_PATH"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --strict "$DMG_PATH"
DMG_TEAM="$(codesign -dv "$DMG_PATH" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$DMG_TEAM" == "$TEAM" ]] || { echo 'DMG and app signing teams differ.' >&2; exit 1; }
hdiutil verify "$DMG_PATH"
cp "$STAGE_DIR/ReleaseInfo.txt" "$OUTPUT_DIR/LiveCopilot-$VERSION-ReleaseInfo.txt"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG_NAME" "LiveCopilot-$VERSION-ReleaseInfo.txt" > SHA256SUMS.txt
)
echo "Created: $DMG_PATH"
echo "Submit and staple the DMG, then run finalize-release.sh to verify and refresh checksums."
