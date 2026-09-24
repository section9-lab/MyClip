#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build --target MyClipCore
myclip_package_build="$(swift build --show-bin-path)"
myclip_test_build="build/screenshot-document-tests"
mkdir -p "$myclip_test_build"

# Compile the real app model and capture boundary for the minimum supported OS.
# Preview mode keeps the checks local and never starts capture or an AI agent.
swiftc -parse-as-library -swift-version 6 \
    -target "$(uname -m)-apple-macosx13.0" \
    -I "$myclip_package_build/Modules" "$myclip_package_build"/MyClipCore.build/*.o \
    MyClip/App/PermissionCoordinator.swift \
    MyClip/Features/Library/AgentRuntime.swift \
    MyClip/Features/Library/FocusedCaptureService.swift \
    MyClip/Features/Library/WindowImageCapture.swift \
    MyClip/Features/Library/AgentSessionCoordinator.swift \
    MyClip/Features/Library/MyClipModel*.swift \
    Tests/MyClipAppTests/ScreenshotDocumentTests.swift \
    -o "$myclip_test_build/ScreenshotDocumentTests"
"$myclip_test_build/ScreenshotDocumentTests"
