#!/usr/bin/env bash
#
# scripts/bootstrap.sh —— 准备构建环境并生成 Prism.xcodeproj。
#
# XcodeGen 的查找顺序（第一个可用的胜出）：
#   1. PATH 里的 xcodegen（brew 正常安装的情况）
#   2. 仓库内 .tools/xcodegen/bin/xcodegen（bootstrap 上次下载的副本）
#   3. brew install xcodegen
#   4. 从 GitHub Releases 下载官方 zip 解包到 .tools/
#
# 第 4 步是兜底：本机 Homebrew 前缀 /opt/homebrew 对进程只读，brew install 会失败，
# 因此不依赖 brew 成功。

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# 与 https://github.com/yonaskolb/XcodeGen/releases 对齐；升级时只改这一处。
XCODEGEN_VERSION="2.46.0"

log() { prism_log "$@"; }

find_xcodegen() {
    if command -v xcodegen >/dev/null 2>&1; then
        command -v xcodegen
        return 0
    fi

    local local_bin="$PRISM_TOOLS_DIR/xcodegen/bin/xcodegen"
    if [[ -x "$local_bin" ]]; then
        printf '%s\n' "$local_bin"
        return 0
    fi

    return 1
}

install_with_brew() {
    command -v brew >/dev/null 2>&1 || return 1

    log "尝试 brew install xcodegen ..."
    if brew install xcodegen >/dev/null 2>&1 && command -v xcodegen >/dev/null 2>&1; then
        return 0
    fi

    prism_warn "brew install 失败（常见原因：Homebrew 前缀不可写），改用官方二进制兜底"
    return 1
}

install_from_release() {
    local url="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
    local archive="$PRISM_TOOLS_DIR/xcodegen.zip"

    command -v curl >/dev/null 2>&1 || return 1

    log "下载 XcodeGen ${XCODEGEN_VERSION} → .tools/"
    if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$archive" "$url"; then
        prism_warn "下载失败：$url"
        rm -f "$archive"
        return 1
    fi

    rm -rf "$PRISM_TOOLS_DIR/xcodegen"
    if ! unzip -q -o "$archive" -d "$PRISM_TOOLS_DIR"; then
        prism_warn "解压失败：$archive"
        rm -f "$archive"
        return 1
    fi
    rm -f "$archive"

    [[ -x "$PRISM_TOOLS_DIR/xcodegen/bin/xcodegen" ]]
}

prism_require_xcode

XCODEGEN_BIN=""
if XCODEGEN_BIN="$(find_xcodegen)"; then
    log "使用 XcodeGen: ${XCODEGEN_BIN} （$("$XCODEGEN_BIN" --version | head -1)）"
else
    if install_with_brew && XCODEGEN_BIN="$(find_xcodegen)"; then
        log "已通过 Homebrew 安装 XcodeGen: $XCODEGEN_BIN"
    else
        install_from_release || prism_die "XcodeGen 安装失败：brew 不可写且官方二进制下载失败。请手动安装后重试。"
        XCODEGEN_BIN="$PRISM_TOOLS_DIR/xcodegen/bin/xcodegen"
        log "已安装本地副本: $XCODEGEN_BIN"
    fi
fi

# XcodeGen 需要 share/xcodegen 里的 SettingPresets；用下载副本时同目录即自带。
log "生成 Prism.xcodeproj（project.yml 是唯一事实来源）"
cd "$PRISM_ROOT"
"$XCODEGEN_BIN" generate --spec project.yml

[[ -d "$PRISM_ROOT/Prism.xcodeproj" ]] || prism_die "生成失败：Prism.xcodeproj 不存在"
log "完成：Prism.xcodeproj 已生成"
