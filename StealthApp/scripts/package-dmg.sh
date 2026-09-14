#!/bin/bash
# Package a clean checkout, or preserve a previously validated app's signature.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO_DIR="$PWD"
APP_PATH=""
APP_SOURCE_REF=""
OUTPUT_DIR="$REPO_DIR/dist"

usage() {
  echo "Usage: $0 [--app /path/LiveCopilot.app --app-source-ref COMMIT] [--output /path/dist]"
  echo "Without --app, builds Release and ad-hoc signs a staging copy. Never reads API keys."
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app|--app-source-ref|--output)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 1; }
      case "$1" in
        --app) APP_PATH="$2" ;;
        --app-source-ref) APP_SOURCE_REF="$2" ;;
        --output) OUTPUT_DIR="$2" ;;
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
BUILD_NEW_APP=false
if [[ -z "$APP_PATH" ]]; then
  [[ -z "$APP_SOURCE_REF" ]] || { echo "--app-source-ref requires --app." >&2; exit 1; }
  ./StealthApp/scripts/build.sh
  APP_PATH="$REPO_DIR/StealthApp/build/Build/Products/Release/LiveCopilot.app"
  APP_SOURCE_REF="$RELEASE_COMMIT"
  BUILD_NEW_APP=true
else
  [[ -n "$APP_SOURCE_REF" ]] || { echo "Supply the validated app's --app-source-ref." >&2; exit 1; }
  APP_SOURCE_REF="$(git rev-parse --verify "$APP_SOURCE_REF^{commit}")"
  git diff --quiet "$APP_SOURCE_REF" "$RELEASE_COMMIT" -- \
    StealthApp/Sources StealthApp/Resources StealthApp/project.yml || {
    echo "App inputs changed since --app-source-ref. Build a new app instead." >&2; exit 1;
  }
  codesign --verify --deep --strict "$APP_PATH"
fi
[[ -f "$APP_PATH/Contents/Info.plist" ]] || { echo "App bundle not found." >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/livecopilot-dmg.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
ditto --noextattr --norsrc "$APP_PATH" "$STAGE_DIR/LiveCopilot.app"
STAGED_APP="$STAGE_DIR/LiveCopilot.app"
if [[ "$BUILD_NEW_APP" == true ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date -u +%Y%m%d.%H%M%S)" "$STAGED_APP/Contents/Info.plist"
  codesign --force --sign - --entitlements StealthApp/Resources/LiveCopilot.entitlements "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"
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
SIGNATURE="$(codesign -dv "$STAGED_APP" 2>&1 | sed -n 's/^Signature=//p')"
SIGNATURE="${SIGNATURE:-code-signed; notarization not asserted}"
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
This packaging script does not perform Apple notarization.
EOF

hdiutil create -volname "LiveCopilot $VERSION" -srcfolder "$STAGE_DIR" \
  -fs HFS+ -format UDZO "$DMG_PATH"
hdiutil verify "$DMG_PATH"
cp "$STAGE_DIR/ReleaseInfo.txt" "$OUTPUT_DIR/LiveCopilot-$VERSION-ReleaseInfo.txt"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG_NAME" "LiveCopilot-$VERSION-ReleaseInfo.txt" > SHA256SUMS.txt
)
echo "Created: $DMG_PATH"
echo "Checksums: $OUTPUT_DIR/SHA256SUMS.txt"
