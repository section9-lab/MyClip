#!/usr/bin/env bash
# Cloud REST contracts, scheduler and native UI checks; no account, network or XCTest runtime required.
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build --target MyClipCore
cloud_package_build="$(swift build --show-bin-path)"
cloud_core_objects=()
while IFS= read -r object; do cloud_core_objects+=("$object"); done < <(
    python3 -c 'import json,sys; print("\n".join(v["object"] for v in json.load(open(sys.argv[1])).values() if "object" in v))' \
        "$cloud_package_build/MyClipCore.build/output-file-map.json"
)
mkdir -p build/cloud-sync-verification
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx13.0" \
    -I "$cloud_package_build/Modules" "${cloud_core_objects[@]}" \
    MyClip/App/Model/CloudSyncController.swift MyClip/App/Model/GoogleCloudOAuth.swift \
    MyClip/Features/Memory/MemoryCloudSyncView.swift Tests/CloudSync/CloudSyncChecks.swift \
    Tests/CloudSync/CloudSyncAppChecks.swift -o build/cloud-sync-verification/CloudSyncChecks
build/cloud-sync-verification/CloudSyncChecks
