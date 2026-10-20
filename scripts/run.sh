#!/usr/bin/env bash
#
# scripts/run.sh —— 构建并启动 App。
#
# 无头 / 无图形会话环境下 `open` 会失败：脚本会退化为只校验二进制存在，
# 并以非零码提示，方便 CI 里区分「构建坏了」和「没有窗口服务器」。

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

"$PRISM_ROOT/scripts/build.sh"

APP_PATH="$PRISM_BUILD_DIR/Build/Products/Debug/Prism.app"
BINARY="$APP_PATH/Contents/MacOS/Prism"

[[ -x "$BINARY" ]] || prism_die "找不到可执行文件：$BINARY"

prism_log "启动 $APP_PATH"
if open "$APP_PATH"; then
    prism_log "已交给 LaunchServices 启动"
else
    prism_warn "open 失败（可能没有图形会话）。二进制本身已构建成功：$BINARY"
    exit 1
fi
