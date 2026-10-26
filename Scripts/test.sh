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
    *) echo "Usage: bash Scripts/test.sh [all|core|cloud-sync|scripts|benchmark|app [TestName...]]" >&2; exit 2 ;;
esac
