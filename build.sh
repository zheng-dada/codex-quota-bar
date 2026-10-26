#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build_dir="${CODEX_QUOTA_BUILD_DIR:-.build}"
mkdir -p "$build_dir/module-cache"
app="dist/Codex Quota Bar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
arch="$(uname -m)"
xcrun swiftc -swift-version 5 -O \
  -target "${arch}-apple-macosx13.0" \
  -module-cache-path "$build_dir/module-cache" \
  -framework AppKit -framework SwiftUI -framework ServiceManagement \
  Sources/QuotaModels.swift Sources/CodexClient.swift Sources/QuotaApp.swift Sources/main.swift \
  -o "$app/Contents/MacOS/CodexQuotaBar"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "已构建：$app"
