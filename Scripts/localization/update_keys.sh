#!/usr/bin/env bash
# Collects every localizable key the Swift compiler extracts (SWIFT_EMIT_LOC_STRINGS) from the app target and from the
# MyClipCore package, then adds missing keys to the two String Catalogs and reports keys that still lack translations.
# Run after adding or changing UI strings. Pass `--translations DIR` to merge <lang>.json files at the same time.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
WORK="${LOCALIZATION_WORK_DIR:-build/localization}"
DERIVED="${DERIVED_DATA_PATH:-build/DerivedData}"
rm -rf "$WORK"; mkdir -p "$WORK/core"

# The compiler writes one .stringsdata per source file; keys there are exactly what the runtime looks up
# (`xcodebuild -exportLocalizations` would rewrite multi-argument keys into positional %1$@ form, which is not).
xcrun xcodebuild -project MyClip.xcodeproj -scheme MyClip -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED" build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" >/dev/null
xcrun swift build --target MyClipCore --scratch-path "$WORK/swiftpm" -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/core" >/dev/null

python3 Scripts/localization/merge_translations.py --work "$WORK" \
  --app-stringsdata "$DERIVED/Build/Intermediates.noindex/MyClip.build/Debug/MyClip.build/Objects-normal" "$@"
