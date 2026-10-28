#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_dir="${CODEX_QUOTA_BUILD_DIR:-.build}"
mkdir -p "$build_dir/module-cache"
xcrun swiftc -O -swift-version 5 -module-cache-path "$build_dir/module-cache" \
  Sources/SessionFileWatcher.swift Sources/RunMetrics.swift Tests/Performance/main.swift \
  -o "$build_dir/quota-performance"
"$build_dir/quota-performance" parser
"$build_dir/quota-performance" idle "${CODEX_QUOTA_PERF_SECONDS:-60}"
