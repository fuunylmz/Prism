#!/usr/bin/env bash
#
# scripts/clean.sh —— 清理构建产物。
#
#   ./scripts/clean.sh          删 build/ 与 .build/（保留 .tools/ 里的 xcodegen）
#   ./scripts/clean.sh --all    额外删掉 Prism.xcodeproj 与 .tools/
#
# 不动任何源码、docs、git 历史。

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

cd "$PRISM_ROOT"

prism_log "清理 build/ 与 .build/"
rm -rf "$PRISM_BUILD_DIR" "$PRISM_SPM_BUILD_DIR"

if [[ "${1:-}" == "--all" ]]; then
    prism_log "清理 Prism.xcodeproj 与 .tools/（下次 build 会重新生成/下载）"
    rm -rf "$PRISM_ROOT/Prism.xcodeproj" "$PRISM_TOOLS_DIR"
fi

prism_log "完成"
