#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build --target MyClipCore
package_build="$(swift build --show-bin-path)"
test_build="build/capture-lifecycle-tests"
mkdir -p "$test_build"

# Compile the real app model with a capture double so no system permissions,
# screen recordings, or signed-in agents are needed for these lifecycle checks.
swiftc -parse-as-library -swift-version 6 \
    -target "$(uname -m)-apple-macosx13.0" \
    -I "$package_build/Modules" "$package_build"/MyClipCore.build/*.o \
    MyClip/Features/Library/AgentRuntime.swift \
    MyClip/Features/Library/MyClipModel.swift \
    Tests/MyClipAppTests/CaptureLifecycleTests.swift \
    -o "$test_build/CaptureLifecycleTests"
"$test_build/CaptureLifecycleTests"
