#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
myclip_test_build="build/task-board-scroll-tests"
mkdir -p "$myclip_test_build"

xcodebuild -quiet -project MyClip.xcodeproj -scheme MyClip -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
myclip_products="build/Build/Products/Debug"
myclip_objects=()
for object in build/Build/Intermediates.noindex/MyClip.build/Debug/MyClip.build/Objects-normal/"$(uname -m)"/*.o; do
    [[ "$object" == */MyClipApp.o ]] || myclip_objects+=("$object")
done

swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx13.0" \
    -I "$myclip_products" "${myclip_objects[@]}" "$myclip_products"/*.o \
    Tests/MyClipAppTests/TaskBoardScrollTests.swift -o "$myclip_test_build/TaskBoardScrollTests"
"$myclip_test_build/TaskBoardScrollTests" "$@"
