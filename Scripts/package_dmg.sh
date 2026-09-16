#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build/DerivedData}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/MyClip.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' MyClip/Supporting/Info.plist)"
DMG_PATH="dist/MyClip-$VERSION.dmg"
DMG_ROOT="build/dmg-root"
CODE_SIGN_ARGS=()

if [[ -n "${CODE_SIGN_IDENTITY_OVERRIDE:-}" ]]; then
  CODE_SIGN_ARGS+=(CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY_OVERRIDE")
elif [[ "${CI:-}" == "true" ]]; then
  CODE_SIGN_ARGS+=(CODE_SIGN_IDENTITY="-")
fi

xcodebuild \
  -project MyClip.xcodeproj \
  -scheme MyClip \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  ${CODE_SIGN_ARGS[@]+"${CODE_SIGN_ARGS[@]}"} \
  build

rm -rf "$DMG_ROOT" "$DMG_PATH"
mkdir -p "$DMG_ROOT" dist
cp -R "$APP_PATH" "$DMG_ROOT/MyClip.app"
ln -s /Applications "$DMG_ROOT/Applications"

hdiutil create \
  -volname MyClip \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ -n "${DMG_PATH_OUTPUT:-}" ]]; then
  printf '%s\n' "$DMG_PATH" > "$DMG_PATH_OUTPUT"
fi

echo "$DMG_PATH"
