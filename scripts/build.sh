#!/usr/bin/env bash
#
# scripts/build.sh —— 生成工程并构建 Prism.app（Debug）。
#
# 产物：build/Build/Products/Debug/Prism.app
# 失败即非零退出（set -e + xcodebuild 的返回码）。

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

prism_require_xcode
prism_ensure_manifest_sandbox_off
"$PRISM_ROOT/scripts/bootstrap.sh"

prism_log "xcodebuild build（Debug，arm64，ad-hoc 签名）"
cd "$PRISM_ROOT"

xcodebuild \
    -project Prism.xcodeproj \
    -scheme Prism \
    -configuration Debug \
    -derivedDataPath build \
    -destination 'platform=macOS' \
    build

APP_PATH="$PRISM_BUILD_DIR/Build/Products/Debug/Prism.app"
[[ -d "$APP_PATH" ]] || prism_die "构建成功但未找到产物：$APP_PATH"

prism_log "构建完成：$APP_PATH"
