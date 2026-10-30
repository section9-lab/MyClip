#!/usr/bin/env bash
# Real Core/model/Backstage checks without Xcode or XCTest. Requires a macOS GUI session.
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build --target MyClipCore
package_build="$(swift build --show-bin-path)"
objects=()
while IFS= read -r object; do objects+=("$object"); done < <(
    python3 -c 'import json,sys; print("\n".join(v["object"] for v in json.load(open(sys.argv[1])).values() if "object" in v))' \
        "$package_build/MyClipCore.build/output-file-map.json"
)
mkdir -p build/performance
backstage_source="${MYCLIP_PERFORMANCE_BACKSTAGE_SOURCE:-MyClip/Features/Agent/BackstageView.swift}"
usage_checks=(Tests/Performance/UsageDashboardChecks.swift)
if [[ -n "${MYCLIP_PERFORMANCE_BACKSTAGE_SOURCE:-}" ]]; then
    usage_checks=(-D MYCLIP_PERFORMANCE_BASELINE)
fi
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx13.0" \
    -I "$package_build/Modules" "${objects[@]}" \
    MyClip/App/PermissionCoordinator.swift MyClip/App/Model/*.swift \
    MyClip/Features/Agent/AgentRuntime.swift MyClip/Features/Agent/AgentSessionCoordinator.swift \
    MyClip/Features/Agent/AgentCharacterView.swift MyClip/Features/Agent/AgentStatusIcon.swift \
    MyClip/Features/Agent/PermissionRequestView.swift MyClip/Features/Agent/ExecutionDetailView.swift "$backstage_source" \
    MyClip/UI/LibraryCompatibility.swift "${usage_checks[@]}" \
    Tests/Performance/PerformanceChecks.swift \
    -o build/performance/PerformanceChecks
build/performance/PerformanceChecks
