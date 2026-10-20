#!/usr/bin/env bash
#
# scripts/test.sh —— 跑测试。
#
# 默认只跑纯逻辑层：`swift test`（PrismCoreTests / EmbyAPITests，无需启动 App）。
# 需要连 App target 一起测时：`XCODE_TESTS=1 ./scripts/test.sh`
#   —— 目前 scheme 里没有配置 test target，脚本会自动跳过并提示，不算失败。
#
# 失败即非零退出。

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

prism_require_xcode
cd "$PRISM_ROOT"

prism_log "swift test（纯逻辑层，Xcode 工具链 + 关闭 SwiftPM 沙箱）"
# shellcheck disable=SC2046
swift test $(prism_swift_flags)

if [[ "${XCODE_TESTS:-0}" == "1" ]]; then
    prism_ensure_manifest_sandbox_off
    "$PRISM_ROOT/scripts/bootstrap.sh"

    # 只有 scheme 里真的挂了 test target，xcodebuild test 才有意义。
    if grep -q '<TestableReference' "$PRISM_ROOT/Prism.xcodeproj/xcshareddata/xcschemes/Prism.xcscheme" 2>/dev/null; then
        prism_log "xcodebuild test"
        # shellcheck disable=SC2046
        xcodebuild $(prism_xcodebuild_flags) -configuration Debug test
    else
        prism_warn "scheme Prism 未配置 test target，跳过 xcodebuild test（swift test 已覆盖逻辑层）"
    fi
else
    prism_log "提示：XCODE_TESTS=1 ./scripts/test.sh 可额外跑 xcodebuild test"
fi

prism_log "测试通过"
