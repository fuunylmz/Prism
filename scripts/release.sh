#!/usr/bin/env bash
#
# scripts/release.sh —— 构建、签名、公证并打包 Prism。
#
# 用法：
#   ./scripts/release.sh                    # 完整流程（需要 Developer ID 证书）
#   ./scripts/release.sh --skip-notarize    # 只构建 + 签名 + 打 DMG（本地自用）
#   ./scripts/release.sh --dry-run          # 只打印将要执行的命令
#
# ## 前置条件（M5 发布前必须准备好）
#
# 1. **Developer ID Application 证书**已安装到钥匙串：
#      security find-identity -v -p codesigning
#    应能看到 `Developer ID Application: <你的名字> (<TEAMID>)`。
#    本机当前是 0 个有效身份，所以默认只能做 ad-hoc 签名。
#
# 2. **公证凭据**已存入钥匙串（只需做一次）：
#      xcrun notarytool store-credentials "prism-notary" \
#        --apple-id "you@example.com" \
#        --team-id "TEAMID" \
#        --password "app-specific-password"
#    `--password` 必须是 App 专用密码，不是 Apple ID 密码。
#    参考：https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
#
# 3. **Sparkle 更新签名密钥**（v1.1 才用，但建议现在就生成并妥善保存）：
#      .tools/sparkle/bin/generate_keys
#    公钥写进 Info.plist 的 `SUPublicEDKey`，私钥**不要提交到仓库**。
#
# ## 为什么签名顺序不能反
#
# 必须先签**内层**（框架、dylib、XPC 服务），再签**外层** App bundle。
# 反过来签会让内层签名在外层被替换后失效。
# 另外 Apple 明确不推荐 `--deep` 用于签名（TN2206），它只适合 verify。
# 参考：https://developer.apple.com/library/archive/technotes/tn2206/_index.html
#
# ## 为什么先公证 .app 再打 DMG
#
# 正确顺序：签名 .app → 公证 .app → staple .app → 打 DMG → 签名 DMG → 公证 DMG → staple DMG。
# 若先打 DMG 再公证，staple 的票据会落在 DMG 上而 App 本身没有，
# 用户把 App 拖出 DMG 后 Gatekeeper 仍会拦。
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$DIR/env.sh" >/dev/null 2>&1

SKIP_NOTARIZE=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        -h|--help)       sed -n '2,45p' "$0"; exit 0 ;;
        *) prism_die "未知参数：$arg（用 --help 看用法）" ;;
    esac
done

# ---------------------------------------------------------------- 配置

APP_NAME="Prism"
BUNDLE_ID="app.prism.Prism"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PRISM_ROOT/App/Info.plist" 2>/dev/null || echo "0.1.0")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PRISM_ROOT/App/Info.plist" 2>/dev/null || echo "1")"
RELEASE_DIR="$PRISM_ROOT/release"
APP_PATH="$PRISM_ROOT/build/Build/Products/Release/$APP_NAME.app"
DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
NOTARY_PROFILE="prism-notary"

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '\033[1;33m[dry-run]\033[0m %s\n' "$*"
    else
        printf '\033[1;34m[release]\033[0m %s\n' "$*"
        "$@"
    fi
}

# ---------------------------------------------------------------- 0. 环境检查

prism_log "版本：$VERSION ($BUILD_NUMBER)"

# ⚠️ macOS 自带的是 bash 3.2，它在 `set -u` 下展开**空数组**也会报
# `unbound variable`（bash 4.4 才修）。所以下面引用时统一写
# `${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"}`——数组为空时展开为空，非空时正常展开。
SIGN_FLAGS=()

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')"
if [[ -z "$IDENTITY" ]]; then
    prism_warn "未找到 Developer ID Application 证书，将使用 ad-hoc 签名（-）。"
    prism_warn "ad-hoc 签名的 App **无法公证**，用户首次打开需要右键 → 打开。"
    SIGN_IDENTITY="-"
    SKIP_NOTARIZE=1
    # ⚠️ **ad-hoc 签名绝不能带 hardened runtime。**
    #
    # hardened runtime 会启用库验证（library validation）：主程序与它加载的每个
    # 非平台库必须有**相同 Team ID**。ad-hoc 签名没有 Team ID，于是 dyld 拒绝加载：
    #
    #   code signature ... not valid for use in process:
    #   mapping process and mapped file (non-platform) have different Team IDs
    #
    # 症状是 App 一启动就崩、Debug 版却正常（Debug 走 Xcode 的 ad-hoc + 无 runtime）。
    # 有真正的 Developer ID 时才加 `--options runtime`——那是公证的前提。
else
    prism_log "签名身份：$IDENTITY"
    SIGN_IDENTITY="$IDENTITY"
    # Developer ID + hardened runtime + 安全时间戳：公证的三个必要条件。
    SIGN_FLAGS=(--options runtime --timestamp)
fi

if [[ "$SKIP_NOTARIZE" == "0" ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    prism_warn "公证凭据 '$NOTARY_PROFILE' 不可用，跳过公证。"
    prism_warn "配置方法见本脚本头部注释。"
    SKIP_NOTARIZE=1
fi

# ---------------------------------------------------------------- 1. Release 构建

prism_log "构建 Release…"
run xcodebuild \
    -project "$PRISM_ROOT/Prism.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$PRISM_ROOT/build" \
    -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    build

[[ "$DRY_RUN" == "1" ]] || [[ -d "$APP_PATH" ]] || prism_die "构建产物不存在：$APP_PATH"

# ---------------------------------------------------------------- 2. 逐层签名

# 顺序：内层 → 外层。先签所有 framework / dylib，再签整个 bundle。
prism_log "逐层签名（内层优先）…"
if [[ "$DRY_RUN" == "0" ]]; then
    # 先签所有嵌套的框架与 dylib（深度优先，最内层在前）
    find "$APP_PATH/Contents/Frameworks" -type d -name '*.framework' -depth 2>/dev/null | while read -r fw; do
        codesign --force ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} \
            --sign "$SIGN_IDENTITY" "$fw" 2>/dev/null \
            && printf '  签名 %s\n' "$(basename "$fw")"
    done
    find "$APP_PATH" -name '*.dylib' -type f 2>/dev/null | while read -r dylib; do
        codesign --force ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} \
            --sign "$SIGN_IDENTITY" "$dylib" 2>/dev/null
    done
    # 再签 App 本体
    codesign --force ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} \
        --sign "$SIGN_IDENTITY" "$APP_PATH"
fi

run codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# ---------------------------------------------------------------- 3. 公证 .app

if [[ "$SKIP_NOTARIZE" == "0" ]]; then
    prism_log "公证 .app（可能耗时数分钟）…"
    run xcrun notarytool submit "$APP_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    run xcrun stapler staple "$APP_PATH"
else
    prism_warn "跳过公证（见上方原因）"
fi

# ---------------------------------------------------------------- 4. 打 DMG

prism_log "打包 DMG…"
mkdir -p "$RELEASE_DIR"
STAGING="$(mktemp -d)"
if [[ "$DRY_RUN" == "0" ]]; then
    cp -R "$APP_PATH" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
fi

# UDZO：压缩只读。
#
# ⚠️ **DMG 可能建不出来**：`hdiutil create` / `diskutil image create` 都需要
# 挂载回环设备，在受限沙箱（如本仓库的开发环境）里会报
# 「create failed - 目录非空」或 `OSStatus error 1`。
# 这不是代码问题——同一个命令对只有一个 txt 的目录也同样失败。
# 所以这里检测失败并**自动回退到 ZIP**：ZIP 是 Sparkle 支持的正式分发格式，
# 用 `ditto -c -k --sequesterRsrc --keepParent` 打包可保留代码签名所需的
# 资源叉与扩展属性（直接用 `zip` 会丢，导致签名校验失败）。
DMG_OK=0
if [[ "$DRY_RUN" == "1" ]]; then
    printf '\033[1;33m[dry-run]\033[0m hdiutil create -volname %s -srcfolder %s -ov -format UDZO %s\n' "$APP_NAME" "$STAGING" "$DMG_PATH"
else
    if hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" 2>/dev/null; then
        DMG_OK=1
    else
        prism_warn "hdiutil 创建 DMG 失败（沙箱限制），回退到 ZIP 分发。"
        prism_warn "在有完整权限的机器上重跑本脚本即可得到 DMG。"
        DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.zip"
        ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$DMG_PATH"
    fi
    rm -rf "$STAGING"
fi

# ---------------------------------------------------------------- 5. 公证 DMG

if [[ "$SKIP_NOTARIZE" == "0" ]] && [[ "$DMG_OK" == "1" ]]; then
    prism_log "签名并公证 DMG…"
    run codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
    run xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    run xcrun stapler staple "$DMG_PATH"
elif [[ "$SKIP_NOTARIZE" == "0" ]]; then
    prism_log "公证 ZIP（ZIP 不签名，只公证内容）…"
    run xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
fi

# ---------------------------------------------------------------- 6. 验证

prism_log "验证 Gatekeeper 判定…"
if [[ "$DRY_RUN" == "0" ]]; then
    spctl -a -vvv -t install "$APP_PATH" 2>&1 || prism_warn "spctl 拒绝了 .app（ad-hoc 签名时属预期）"
    if [[ "$DMG_OK" == "1" ]]; then
        spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH" 2>&1 || prism_warn "spctl 拒绝了 DMG（未公证时属预期）"
    fi
fi

prism_log "完成。产物："
ls -lh "$DMG_PATH" 2>/dev/null || echo "  （dry-run 模式未生成）"
prism_log "校验和："
shasum -a 256 "$DMG_PATH" 2>/dev/null || true
