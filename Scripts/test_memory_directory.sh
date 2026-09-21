#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
myclip_test_build="build/memory-directory-tests"
mkdir -p "$myclip_test_build"

xcodebuild -quiet -project MyClip.xcodeproj -scheme MyClip -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
myclip_products="build/Build/Products/Debug"

# Keep the test in the same file as the private production directory view.
cat MyClip/Features/Library/MyClipViews.swift Tests/MyClipAppTests/MemoryDirectoryTests.swift \
    > "$myclip_test_build/MemoryDirectoryTestsWithViews.swift"
myclip_sources=(MyClip/App/PermissionCoordinator.swift)
for myclip_source in MyClip/Features/Library/*.swift; do
    if [[ "$myclip_source" != */MyClipViews.swift ]]; then
        myclip_sources+=("$myclip_source")
    fi
done

swiftc -parse-as-library -swift-version 6 \
    -target "$(uname -m)-apple-macosx13.0" \
    -I "$myclip_products" \
    "$myclip_products/MyClipCore.o" "$myclip_products/MarkdownUI.o" \
    "$myclip_products/NetworkImage.o" "$myclip_products/cmark-gfm.o" \
    "$myclip_products/cmark-gfm-extensions.o" \
    "${myclip_sources[@]}" "$myclip_test_build/MemoryDirectoryTestsWithViews.swift" \
    -o "$myclip_test_build/MemoryDirectoryTests"
"$myclip_test_build/MemoryDirectoryTests"
