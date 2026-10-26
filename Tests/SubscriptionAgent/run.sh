#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build --target MyClipCore
component_build="$(swift build --show-bin-path)"
component_objects=()
while IFS= read -r object; do component_objects+=("$object"); done < <(
  python3 -c 'import json,sys; print("\n".join(v["object"] for v in json.load(open(sys.argv[1])).values() if "object" in v))' "$component_build/MyClipCore.build/output-file-map.json"
)
mkdir -p build/subscription-tests
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx13.0" -I "$component_build/Modules" "${component_objects[@]}" \
  MyClip/Features/Agent/AgentRuntime.swift Tests/SubscriptionAgent/ManagedRuntimeChecks.swift -o build/subscription-tests/ManagedRuntimeChecks
build/subscription-tests/ManagedRuntimeChecks "$@"
