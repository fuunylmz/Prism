# 发布流程

> 状态：**脚本已端到端验证**（DMG 27 MB，挂载后 App 可启动）。
> 唯一未完成项是**公证**——需要你的 Apple Developer ID 证书（本机 0 个有效身份）。

---

## 一条命令

```bash
./scripts/release.sh                 # 完整流程：构建 → 签名 → 公证 → DMG
./scripts/release.sh --skip-notarize # 本地自用：构建 → ad-hoc 签名 → DMG
./scripts/release.sh --dry-run       # 只打印命令，不执行
```

产物在 `release/`（已 gitignore）。

---

## 要做真正的公证，你需要准备三样

### 1. Developer ID Application 证书

登录 [developer.apple.com](https://developer.apple.com/account/resources/certificates) 创建
**Developer ID Application** 证书，双击装进钥匙串。验证：

```bash
security find-identity -v -p codesigning
# 应看到：1) ABC123... "Developer ID Application: Your Name (TEAMID)"
```

### 2. App 专用密码

在 [appleid.apple.com](https://appleid.apple.com/account/manage) → 登录与安全 → App 专用密码。
**不是**你的 Apple ID 密码。

### 3. 存进钥匙串（只需一次）

```bash
xcrun notarytool store-credentials "prism-notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

之后 `./scripts/release.sh` 会自动检测到证书与凭据，走完整公证流程。

---

## 为什么脚本这样设计

### ad-hoc 签名绝不能带 hardened runtime

这是**踩过的坑**：Release 版一启动就崩，Debug 版却正常。

```
dyld: Library not loaded: @rpath/AetherLibavcodec.framework/...
Reason: code signature ... not valid for use in process:
        mapping process and mapped file (non-platform) have different Team IDs
```

原因：hardened runtime 会启用**库验证**，要求主程序与每个非平台库有相同的 Team ID。
ad-hoc 签名没有 Team ID，于是 dyld 拒绝加载嵌入的 FFmpeg 框架。

所以脚本按签名身份分支：
- 有 Developer ID → `--options runtime --timestamp`（公证的必要条件）
- 只有 ad-hoc → **不加** runtime

### 签名顺序：内层优先

先签 `Contents/Frameworks/*.framework` 与所有 `.dylib`，最后签 `.app` 本体。
反过来签会让内层签名在外层被替换后失效。

Apple 明确不推荐用 `--deep` 签名（[TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)），
它只适合 `verify`。

### 先公证 .app，再打 DMG

正确顺序：签名 .app → 公证 .app → staple .app → 打 DMG → 签名 DMG → 公证 DMG → staple DMG。

若先打 DMG 再公证，票据只落在 DMG 上，用户把 App 拖出 DMG 后 Gatekeeper 仍会拦。

### DMG 失败自动回退 ZIP

`hdiutil create` 与 `diskutil image create` 都需要挂载回环设备。在受限环境（如本仓库的开发沙箱）
里会报「create failed - 目录非空」或 `OSStatus error 1`——**对只有一个 txt 的目录也同样失败**，
所以是环境限制不是代码问题。

脚本检测失败后自动改用 `ditto -c -k --sequesterRsrc --keepParent` 打 ZIP。
这个格式 Sparkle 原生支持，且能保留代码签名所需的资源叉（直接用 `zip` 会丢）。

### bash 3.2 的空数组陷阱

macOS 自带 bash 3.2，在 `set -u` 下展开**空数组**也会报 `unbound variable`（bash 4.4 才修）。
脚本里统一写 `${ARR[@]+"${ARR[@]}"}`。

---

## 验收清单

```bash
# 1. 产物存在
ls -lh release/

# 2. 挂载并检查内容
hdiutil attach release/Prism-0.1.0.dmg
ls /Volumes/Prism/          # 应有 Prism.app 与 Applications 快捷方式

# 3. 从 DMG 启动
open -a "/Volumes/Prism/Prism.app" --args -DemoMode YES

# 4. 卸载
hdiutil detach /Volumes/Prism
```

公证通过后额外验证：

```bash
spctl -a -vvv -t install build/Build/Products/Release/Prism.app
# 期望：accepted，source=Notarized Developer ID

xcrun stapler validate release/Prism-0.1.0.dmg
# 期望：The validate action worked!
```

---

## 已知限制

| 项 | 说明 |
|---|---|
| **未公证** | 没有 Developer ID 证书。用户首次打开需右键 → 打开。 |
| **通用二进制** | 66 MB 未压缩 / 27 MB DMG，含 x86_64 + arm64。只发 Apple Silicon 可减半。 |
| **Sparkle 未接** | `AboutView` 里的「检查更新」是 disabled 的，v1.1 再接。 |
| **macOS 15 图标** | 图标按 macOS 26 的「满幅方形 + 系统裁切」规范做，15 上会显示直角方形。 |
