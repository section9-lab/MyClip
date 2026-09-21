#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build --target MyClipCore
myclip_package_build="$(swift build --show-bin-path)"
myclip_test_build="build/agent-activation-tests"
mkdir -p "$myclip_test_build"

swiftc -parse-as-library -swift-version 6 \
    -target "$(uname -m)-apple-macosx13.0" \
    -I "$myclip_package_build/Modules" "$myclip_package_build"/MyClipCore.build/*.o \
    MyClip/Features/Library/AgentRuntime.swift \
    MyClip/Features/Library/MyClipModel.swift \
    Tests/MyClipAppTests/AgentActivationTests.swift \
    -o "$myclip_test_build/AgentActivationTests"
"$myclip_test_build/AgentActivationTests"
