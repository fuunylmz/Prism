# 构建环境须知（所有代理必读）

> 主管实测于 2026-10-21。**遇到构建失败先读这里，不要自行猜测。**

## 1. 必须使用 Xcode 工具链

本机 `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`（CLT），而 CLT 的 swiftpm 无法编译本包。
**所有 `swift` 命令都必须带 `DEVELOPER_DIR`**：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

（Xcode 27.1 装在 `/Applications/Xcode.app`）

## 2. 必须关闭 SwiftPM 沙箱

DSH 的文件沙箱与 `swift build` 内置的 `sandbox-exec` 会冲突，报：

```
sandbox-exec: sandbox_apply: Operation not permitted
error: 'prism': Invalid manifest
```

**解法：始终加 `--disable-sandbox`**。

## 3. 缓存必须放在工作区内

`~/Library/org.swift.swiftpm` 与 `~/Library/Caches` 对当前进程不可写，会导致 module cache 报
`unable to open output file ... Operation not permitted`。**解法：把缓存指到 `.build/cache`**。

## 4. 标准命令（直接复制）

```bash
cd /Users/fuunylmz/Prism

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cache/clang"
export TMPDIR="$PWD/.build/tmp"
mkdir -p "$TMPDIR" "$PWD/.build/cache"

# 构建
swift build --disable-sandbox --cache-path "$PWD/.build/cache"

# 测试
swift test --disable-sandbox --cache-path "$PWD/.build/cache"
```

建议在每次会话开始前 `source scripts/env.sh`（脚手架代理会提供该文件）。

## 4.1 【强制】拉取 Git 依赖时必须完全绕开用户全局 git 配置

本机 `~/.gitconfig` 内容为：

```ini
[credential "https://github.com"]
	helper =
	helper = !/opt/homebrew/bin/gh auth git-credential
```

**关键坑**：`helper =`（空值）只是「清空 helper 列表」，**紧接着的下一行又把 gh helper 加回去了**，所以实际生效的仍是 gh helper。
只设 `GIT_CONFIG_COUNT=1 + 空 helper` 在某些情况下仍会触发弹窗——**已复现两次事故**。

**唯一彻底有效的做法：完全绕开用户的全局/系统 git 配置。**

```bash
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
```

已验证（2026-10-21 主管实测）：加上后 `git ls-remote https://github.com/mpvkit/MPVKit.git HEAD` 正常返回，
**不触发任何钥匙串弹窗**。公开仓库不需要任何凭据。

完整命令形态：

```bash
env GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    swift build --disable-sandbox --cache-path "$PWD/.build/cache"
```

**`scripts/env.sh` 已包含这三行**，`source scripts/env.sh` 之后所有命令自动生效。

### 如果弹窗已经出现了怎么办

**直接点「拒绝」。** 公开仓库不需要凭据，拒绝后 git 会以匿名方式继续，构建不会失败，不需要输入任何密码。
**绝对不要**输入登录密码，也不要点「始终允许」。

**绝对禁止**：
- 不要点击/诱导用户点击钥匙串的「允许」或「始终允许」。
- 不要执行 `security unlock-keychain`、`security find-generic-password -w`。
- 不要用 `git config --global` 修改用户配置（包括试图「修好」它）。
- 不要使用私有仓库或需要 token 的依赖。

## 4.2 【强制】依赖验证用 spike 目录放在工作区内

不要用 `/tmp` 做依赖验证（易残留、不在版本控制内、清理困难）。
统一使用 `/Users/fuunylmz/Prism/.spike/<主题>/`，该目录已被 `.gitignore` 忽略。

## 5. Xcode 工程构建

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Prism.xcodeproj -scheme Prism -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' build
```

## 6. 已知限制

- 本机 `security find-identity -v -p codesigning` 显示 **0 个有效签名身份**：本地只能用 `CODE_SIGN_IDENTITY = "-"`（ad-hoc）。正式签名/公证需要用户提供 Apple Developer ID，属 M5 事项。
- 本机**没有 Docker**：不要尝试 `docker run emby`，需要服务器数据时用 fixture / mock。
- 真实 Emby 服务器由用户后置提供：开发期一律走 Demo Mode + fixture，**禁止把任何真实地址/账号写进代码或测试**。
