#!/usr/bin/env bash
# Run after package_dmg.sh. The signing key is read from stdin by Sparkle, never argv.
set -euo pipefail
cd "$(dirname "$0")/.."

architecture="${MYCLIP_ARCH:-}"
case "$architecture" in
    arm64|x86_64) ;;
    *) echo "Update feeds require MYCLIP_ARCH=arm64 or x86_64." >&2; exit 1 ;;
esac
if [[ -z "${MYCLIP_SPARKLE_PRIVATE_KEY:-}" ]]; then
    echo "MYCLIP_SPARKLE_PRIVATE_KEY is required to sign updates. See docs/app-updates.md." >&2
    exit 1
fi
sparkle_bin="${SPARKLE_BIN:-build/DerivedData-$architecture/SourcePackages/artifacts/sparkle/Sparkle/bin}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' MyClip/Supporting/Info.plist)"
archive="MyClip-$version-$architecture.dmg"
notes="docs/releases/v$version.md"
test -f "dist/$archive"
test -f "$notes"
test -x "$sparkle_bin/generate_appcast"
test -x "$sparkle_bin/sign_update"

printf '%s' "$MYCLIP_SPARKLE_PRIVATE_KEY" | swift Scripts/verify_update_key.swift MyClip/Supporting/Info.plist

feed_work="$(mktemp -d)"
trap 'rm -rf "$feed_work"' EXIT
cp "dist/$archive" "$feed_work/$archive"
cp "$notes" "$feed_work/${archive%.dmg}.md"

# generate_appcast reads the built app's versions, minimum OS, architecture and
# public key. The independent check above rejects a mismatched signing key;
# some Sparkle tool builds only warn about that mismatch and still return success.
# SURequireSignedFeed also makes it sign the XML and embedded release notes.
printf '%s' "$MYCLIP_SPARKLE_PRIVATE_KEY" | "$sparkle_bin/generate_appcast" \
    --ed-key-file - --embed-release-notes \
    --download-url-prefix "https://github.com/section9-lab/MyClip/releases/download/v$version/" \
    --link "https://github.com/section9-lab/MyClip/releases/tag/v$version" \
    -o "$feed_work/appcast.xml" "$feed_work"
printf '%s' "$MYCLIP_SPARKLE_PRIVATE_KEY" | "$sparkle_bin/sign_update" \
    --ed-key-file - --verify "$feed_work/appcast.xml"
cp "$feed_work/appcast.xml" "dist/appcast-$architecture.xml"
