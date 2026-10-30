#!/usr/bin/env bash
# One entry point for local checks and CI. Native app tests require a macOS GUI session.
set -euo pipefail
cd "$(dirname "$0")/.."

suite="${1:-all}"
if [[ $# -gt 0 ]]; then shift; fi
case "$suite" in
    all)
        bash Scripts/test.sh core
        bash Scripts/test.sh cloud-sync
        bash Scripts/test.sh scripts
        bash Scripts/test.sh benchmark
        bash Scripts/test.sh app
        bash Scripts/test.sh performance
        bash Scripts/test.sh updates
        ;;
    core) swift test "$@" ;;
    cloud-sync) bash Tests/CloudSync/run.sh "$@" ;;
    scripts)
        node --test Tests/Adapters/test_ephemeral_codex.cjs
        node --test Tests/SubscriptionAgent/*.test.mjs
        bash Tests/SubscriptionAgent/run.sh
        PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Packaging -v
        ;;
    benchmark)
        swift build --product myclip-mcp
        PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s benchmark/tests -v
        ;;
    app) bash Tests/MyClipAppTests/run.sh "$@" ;;
    performance) bash Tests/Performance/run.sh "$@" ;;
    updates)
        SPARKLE_BIN="${SPARKLE_BIN:-build/app-tests/SourcePackages/artifacts/sparkle/Sparkle/bin}" \
            PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Updates -v
        ;;
    *) echo "Usage: bash Scripts/test.sh [all|core|cloud-sync|scripts|benchmark|app [TestName...]|performance|updates]" >&2; exit 2 ;;
esac
