#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

tests=()
test_args=()
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -- ]]; then shift; test_args=("$@"); break; fi
    tests+=("$1")
    shift
done
if [[ ${#tests[@]} -eq 0 ]]; then
    tests=(AgentActivationTests CaptureLifecycleTests CaptureFilterModelTests ScreenshotDocumentTests
           MemoryDirectoryTests MemoryScrollTests TaskBoardScrollTests)
fi
if [[ ${#test_args[@]} -gt 0 && ${#tests[@]} -ne 1 ]]; then
    echo "Arguments after -- require exactly one test name." >&2
    exit 2
fi
needs_model=false
needs_app=false
for name in "${tests[@]}"; do
    case "$name" in
        AgentActivationTests|CaptureLifecycleTests) needs_model=true ;;
        CaptureFilterModelTests|ScreenshotDocumentTests|MemoryDirectoryTests|MemoryScrollTests|TaskBoardScrollTests) needs_app=true ;;
        *) echo "Unknown app test: $name" >&2; exit 2 ;;
    esac
done

test_build="build/app-tests"
mkdir -p "$test_build/bin"
compiler_args=(-parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx13.0")

if $needs_model; then
    swift build --target MyClipCore
    package_build="$(swift build --show-bin-path)"
    # Use the current build manifest; a renamed source can leave obsolete .o files behind.
    core_objects=()
    while IFS= read -r object; do core_objects+=("$object"); done < <(
        python3 -c 'import json, sys; print("\n".join(v["object"] for v in json.load(open(sys.argv[1])).values() if "object" in v))' \
            "$package_build/MyClipCore.build/output-file-map.json"
    )
    model_sources=(MyClip/App/PermissionCoordinator.swift MyClip/App/Model/*.swift
                   MyClip/Features/Agent/AgentRuntime.swift MyClip/Features/Agent/AgentSessionCoordinator.swift)
fi
if $needs_app; then
    xcodebuild -quiet -project MyClip.xcodeproj -scheme MyClip -configuration Debug \
        -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$test_build" CODE_SIGNING_ALLOWED=NO build
    products="$test_build/Build/Products/Debug"
    app_objects=()
    while IFS= read -r object; do
        [[ "$object" == */MyClipMain.o ]] || app_objects+=("$object")
    done < <(
        python3 -c 'import shlex, sys; print("\n".join(shlex.split(open(sys.argv[1]).read())))' \
            "$test_build/Build/Intermediates.noindex/MyClip.build/Debug/MyClip.build/Objects-normal/$(uname -m)/MyClip.LinkFileList"
    )
fi

for name in "${tests[@]}"; do
    echo "Running $name"
    case "$name" in
        AgentActivationTests|CaptureLifecycleTests)
            # These two suites replace only capture with a test double; all model/storage/ACP code is real.
            swiftc "${compiler_args[@]}" -I "$package_build/Modules" "${core_objects[@]}" \
                "${model_sources[@]}" "Tests/MyClipAppTests/$name.swift" -o "$test_build/bin/$name"
            ;;
        *)
            # Reuse the built application for UI tests instead of maintaining another production source list.
            swiftc "${compiler_args[@]}" -I "$products" "${app_objects[@]}" \
                "Tests/MyClipAppTests/$name.swift" -o "$test_build/bin/$name"
            ;;
    esac
    "$test_build/bin/$name" ${test_args[@]+"${test_args[@]}"}
done
