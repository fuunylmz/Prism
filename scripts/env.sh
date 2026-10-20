#!/usr/bin/env bash
#
# scripts/env.sh —— 所有脚本共享的构建环境。
#
# 用法（在别的脚本里）：
#     source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
#
# 为什么需要这个文件：本机 `xcode-select -p` 指向 CommandLineTools，
# 且 `$HOME` 下的 SwiftPM / Xcode 缓存目录对当前进程不可写。详见 docs/BUILD_ENV.md。
#
# 它只做三件事：
#   1. 强制使用 Xcode 工具链（DEVELOPER_DIR）
#   2. 把模块缓存 / 临时目录 / SwiftPM 与 Xcode 的包缓存全部指到工作区内
#   3. 提供几个所有脚本共用的小工具函数
#
# 注意：这个文件被 source，所以不要在里面 `exit`。

# ---------------------------------------------------------------- 路径

# shellcheck disable=SC2034
PRISM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PRISM_ROOT

export PRISM_BUILD_DIR="$PRISM_ROOT/build"          # xcodebuild -derivedDataPath
export PRISM_SPM_BUILD_DIR="$PRISM_ROOT/.build"     # swift build --scratch-path 默认值
export PRISM_CACHE_DIR="$PRISM_SPM_BUILD_DIR/cache" # 共享缓存根
export PRISM_TOOLS_DIR="$PRISM_ROOT/.tools"         # 工作区内的工具（如 xcodegen 兜底副本）

# xcodebuild 用 DerivedData 里的 SourcePackages，不需要额外 --packageCachePath；
# 但 SwiftPM 自己的 ~/Library/Caches 必须重定向，否则报 Operation not permitted。
export CFFIXED_USER_HOME="$PRISM_BUILD_DIR/home"

# ---------------------------------------------------------------- 工具链

# 允许调用方显式覆盖，否则固定到 Xcode.app（本机 xcode-select 指向 CLT）。
if [[ -z "${DEVELOPER_DIR:-}" || "${DEVELOPER_DIR}" == */CommandLineTools ]]; then
    if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        echo "warning: 未找到 /Applications/Xcode.app，回退到 xcode-select 的路径" >&2
        export DEVELOPER_DIR="$(xcode-select -p)"
    fi
fi
export DEVELOPER_DIR

# ---------------------------------------------------------------- 缓存与临时目录

# 编译器模块缓存：默认落在 /var/folders/... 且不可写。
export CLANG_MODULE_CACHE_PATH="$PRISM_CACHE_DIR/clang"
export SWIFT_MODULECACHE_PATH="$PRISM_CACHE_DIR/swift"
# swift build / swift test 的 --cache-path。
export PRISM_SWIFT_CACHE_PATH="$PRISM_CACHE_DIR"
# 临时目录：系统 TMPDIR 对当前进程不可写，sandbox-exec 会直接失败。
export TMPDIR="$PRISM_SPM_BUILD_DIR/tmp"

mkdir -p \
    "$CLANG_MODULE_CACHE_PATH" \
    "$SWIFT_MODULECACHE_PATH" \
    "$TMPDIR" \
    "$CFFIXED_USER_HOME/Library/Caches" \
    "$PRISM_TOOLS_DIR"

# ---------------------------------------------------------------- Git 凭据

# 本机 ~/.gitconfig 里有：
#     [credential "https://github.com"]
#         helper =
#         helper = !/opt/homebrew/bin/gh auth git-credential
# 注意：空 helper 只是「清空列表」，下一行又把 gh helper 加回去了，所以**实际生效的是 gh helper**。
# SwiftPM / git 解析远程依赖时会调用它去读钥匙串，**触发 macOS 钥匙串授权弹窗**（已发生两次事故）。
#
# 公开仓库不需要任何凭据。最彻底的做法是**完全绕开用户的全局 git 配置**：
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
# 兜底：即使某处仍读取本地配置，也把 helper 列表清空。
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0=

# 若进程已经在弹窗里卡住，提示用户：**直接点「拒绝」即可**，公开仓库不需要凭据，
# 拒绝后 git 会以匿名方式继续，构建不会失败。
prism_git_guard_note() {
    prism_warn "若仍弹出「swift-package 想要使用钥匙串中的 github.com 机密信息」，直接点【拒绝】即可，不需要输入密码。"
}

# ---------------------------------------------------------------- 共用函数

# 统一日志前缀，便于在 CI 日志里 grep。
prism_log()  { printf '\033[1;34m[prism]\033[0m %s\n' "$*"; }
prism_warn() { printf '\033[1;33m[prism] warning:\033[0m %s\n' "$*" >&2; }
prism_die()  { printf '\033[1;31m[prism] error:\033[0m %s\n' "$*" >&2; exit 1; }

# 校验 Xcode 工具链可用；不可用就直接给出可执行的修复建议。
prism_require_xcode() {
    command -v xcodebuild >/dev/null 2>&1 || prism_die "找不到 xcodebuild，请安装 Xcode 26 或 27"
    if ! xcodebuild -version >/dev/null 2>&1; then
        prism_die "xcodebuild 不可用（DEVELOPER_DIR=$DEVELOPER_DIR）。请确认 Xcode.app 已安装并执行过首次启动。"
    fi
}

# swift test 需要的公共参数。--disable-sandbox 是必需的：DSH 文件沙箱与
# SwiftPM 内置 sandbox-exec 冲突，会报 sandbox_apply: Operation not permitted。
prism_swift_flags() {
    printf '%s\n' \
        --disable-sandbox \
        --cache-path "$PRISM_SWIFT_CACHE_PATH" \
        --scratch-path "$PRISM_SPM_BUILD_DIR"
}

# xcodebuild 的公共参数（派生数据统一放 build/）。
prism_xcodebuild_flags() {
    printf '%s\n' \
        -project "$PRISM_ROOT/Prism.xcodeproj" \
        -scheme Prism \
        -derivedDataPath "$PRISM_BUILD_DIR" \
        -destination 'platform=macOS'
}

# ---------------------------------------------------------------- Xcode 包解析

# 本进程运行在 DSH 的文件沙箱里，不能再嵌套 sandbox-exec。Xcode 解析 SPM manifest
# 时默认会套一层 sandbox，于是报：
#     sandbox-exec: sandbox_apply: Operation not permitted
#
# **这个脚本默认不会改你的 Xcode 偏好。**
# 正常路径已由 Package.swift 的 `.unsafeFlags(["-disable-sandbox"])` 解决
# （它同时作用于 swift build 与 xcodebuild）。只有需要在 Xcode GUI 里首次解析包时，
# 才可能要动那个偏好——届时由你手动执行，或显式 PRISM_ALLOW_XCODE_PREF_WRITE=1 让脚本代劳。
prism_ensure_manifest_sandbox_off() {
    if [[ "$(defaults read com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox 2>/dev/null || echo 0)" == "1" ]]; then
        return 0
    fi

    if [[ "${PRISM_ALLOW_XCODE_PREF_WRITE:-0}" != "1" ]]; then
        prism_warn "若 xcodebuild 报 sandbox_apply 失败，请手动执行（会修改 Xcode 全局偏好）："
        prism_warn "  defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES"
        return 0
    fi

    if defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES 2>/dev/null; then
        prism_warn "已关闭 Xcode 的 SPM manifest 沙箱（IDEPackageSupportDisableManifestSandbox=YES）"
    else
        prism_warn "写入 Xcode 偏好 IDEPackageSupportDisableManifestSandbox 失败"
    fi
}
