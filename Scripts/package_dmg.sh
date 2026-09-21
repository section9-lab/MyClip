#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="${CONFIGURATION:-Release}"
MYCLIP_ARCH="${MYCLIP_ARCH:-universal}"
case "$MYCLIP_ARCH" in
  arm64|x86_64) TARGET_ARCHS="$MYCLIP_ARCH"; PACKAGE_SUFFIX="-$MYCLIP_ARCH" ;;
  universal) TARGET_ARCHS="arm64 x86_64"; PACKAGE_SUFFIX="" ;;
  *) echo "Unsupported architecture: $MYCLIP_ARCH" >&2; exit 1 ;;
esac
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build/DerivedData$PACKAGE_SUFFIX}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/MyClip.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' MyClip/Supporting/Info.plist)"
DMG_PATH="dist/MyClip-$VERSION$PACKAGE_SUFFIX.dmg"
DMG_ROOT="build/dmg-root$PACKAGE_SUFFIX"
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
  ARCHS="$TARGET_ARCHS" ONLY_ACTIVE_ARCH=NO \
  ${CODE_SIGN_ARGS[@]+"${CODE_SIGN_ARGS[@]}"} \
  build

ACTUAL_ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/MyClip")"
if [[ "$ACTUAL_ARCHS" != "$TARGET_ARCHS" && ! ( "$MYCLIP_ARCH" == "universal" && "$ACTUAL_ARCHS" == "x86_64 arm64" ) ]]; then
  echo "Unexpected app architecture: $ACTUAL_ARCHS (expected $TARGET_ARCHS)" >&2
  exit 1
fi
codesign --verify --deep --strict "$APP_PATH"

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
