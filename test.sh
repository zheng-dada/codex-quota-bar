#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_dir="${CODEX_QUOTA_BUILD_DIR:-.build}"
mkdir -p "$build_dir/module-cache"
chmod +x Tests/fake-codex.py
xcrun swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" \
  Sources/QuotaModels.swift Sources/CodexClient.swift Tests/main.swift -o "$build_dir/quota-tests"
"$build_dir/quota-tests" "$PWD/Tests/fake-codex.py" "$build_dir/requests.log"
xcrun swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" \
  Sources/SessionFileWatcher.swift Sources/RunMetrics.swift Tests/RunMetrics/main.swift -o "$build_dir/run-metrics-tests"
"$build_dir/run-metrics-tests"
xcrun swiftc -swift-version 5 -module-cache-path "$build_dir/module-cache" \
  -framework AppKit -framework SwiftUI -framework ServiceManagement \
  Sources/QuotaModels.swift Sources/CodexClient.swift Sources/SessionFileWatcher.swift Sources/RunMetrics.swift Sources/QuotaApp.swift Tests/Layout/main.swift \
  -o "$build_dir/quota-layout-tests"
"$build_dir/quota-layout-tests"
