#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
myclip_test_build="build/memory-scroll-tests"
mkdir -p "$myclip_test_build"

xcodebuild -quiet -project MyClip.xcodeproj -scheme MyClip -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
myclip_products="build/Build/Products/Debug"

swiftc -parse-as-library -swift-version 6 \
    -target "$(uname -m)-apple-macosx13.0" \
    -I "$myclip_products" \
    "$myclip_products/MyClipCore.o" "$myclip_products/MarkdownUI.o" \
    "$myclip_products/NetworkImage.o" "$myclip_products/cmark-gfm.o" \
    "$myclip_products/cmark-gfm-extensions.o" \
    MyClip/Features/Library/LibraryCompatibility.swift \
    MyClip/Features/Library/MemoryMarkdownView.swift \
    Tests/MyClipAppTests/MemoryScrollTests.swift \
    -o "$myclip_test_build/MemoryScrollTests"
"$myclip_test_build/MemoryScrollTests"
