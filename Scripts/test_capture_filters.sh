#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build --target MyClipCore
myclip_package_build="$(swift build --show-bin-path)"
myclip_test_build="build/capture-filter-tests"
mkdir -p "$myclip_test_build"

swiftc -parse-as-library -swift-version 6 \
    -target "$(uname -m)-apple-macosx13.0" \
    -I "$myclip_package_build/Modules" "$myclip_package_build"/MyClipCore.build/*.o \
    MyClip/App/PermissionCoordinator.swift \
    MyClip/Features/Library/AgentRuntime.swift \
    MyClip/Features/Library/FocusedCaptureService.swift \
    MyClip/Features/Library/WindowImageCapture.swift \
    MyClip/Features/Library/AgentSessionCoordinator.swift \
    MyClip/Features/Library/MyClipModel*.swift \
    Tests/MyClipAppTests/CaptureFilterModelTests.swift \
    -o "$myclip_test_build/CaptureFilterModelTests"
"$myclip_test_build/CaptureFilterModelTests"
