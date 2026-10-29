#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
analytics_check_dir="$(mktemp -d)"
trap 'rm -rf "$analytics_check_dir"' EXIT
swiftc -parse-as-library MyClip/App/Analytics/AnalyticsState.swift Tests/Analytics/AnalyticsChecks.swift -o "$analytics_check_dir/checks"
"$analytics_check_dir/checks"
