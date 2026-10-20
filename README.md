# Prism

原生 macOS 的 Emby 客户端：SwiftUI 界面 + libmpv 播放内核 + 本地缓存与离线能力。

> 本仓库当前处于 **M0 地基阶段**：骨架已可构建、可运行、可测试，业务功能由各模块 owner 并行填充。
> 规划与任务板见 [docs/ROADMAP.md](docs/ROADMAP.md)，模块契约见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

---

## 环境要求

| 项 | 版本 | 说明 |
|---|---|---|
| macOS | 15+ | 部署目标 `MACOSX_DEPLOYMENT_TARGET = 15.0` |
| Xcode | **26 / 27** | 必须装在 `/Applications/Xcode.app` |
| Swift | 6.x | 语言模式 `.v6`（严格并发） |
| XcodeGen | 2.46.0 | `bootstrap.sh` 自动准备，无需手动装 |
| Homebrew | 本机不可用 | 见下方说明 |

### 本机已知限制

- **brew 不可用**：`/opt/homebrew` 对进程只读，`brew install` 会报 `Operation not permitted`。
  因此 `bootstrap.sh` **不依赖 brew**：找不到 `xcodegen` 时会从 GitHub Releases 下载官方 zip
  解包到 `.tools/xcodegen/`（已被 `.gitignore` 忽略），后续构建直接复用该副本。
- **Xcode 偏好不动手**：正常构建**不需要**修改任何 Xcode 用户级设置。
  嵌套沙箱问题由 `Package.swift` 里的 `.unsafeFlags(["-disable-sandbox"])` 解决，
  它同时作用于 `swift build` 和 `xcodebuild`。

⚠️ **本机 `xcode-select` 指向 CommandLineTools**，直接用 CLT 的 swiftpm 编译会失败。
所有脚本都通过 [`scripts/env.sh`](scripts/env.sh) 强制 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，
并把模块缓存 / 临时目录 / 包缓存全部重定向到工作区内。**遇到构建问题先读 [docs/BUILD_ENV.md](docs/BUILD_ENV.md)**。

---

## 快速开始

```bash
git clone <repo> && cd Prism

./scripts/bootstrap.sh   # 准备 XcodeGen + 生成 Prism.xcodeproj
./scripts/build.sh       # 构建 → build/Build/Products/Debug/Prism.app
./scripts/run.sh         # 构建并启动
./scripts/test.sh        # swift test（纯逻辑层）
./scripts/clean.sh       # 清 build/ 与 .build/；--all 连工程一起删
```

新会话开工前建议先 `source scripts/env.sh`，一次性拿到正确的工具链与缓存变量。

也可以直接用 Xcode 打开 `Prism.xcodeproj`（由 `project.yml` 生成，改完 spec 记得重跑 bootstrap）。

---

## 目录结构

```
project.yml              # Xcode 工程的唯一事实来源（生成 Prism.xcodeproj，勿手改 pbxproj）
Package.swift            # 根 SPM 包：所有 Swift 源码的唯一构建入口
App/                     # 极薄的 App target：@main + Info.plist + entitlements + Assets
Sources/
  PrismCore/             # 基础模型、日志、设置存储、工具（无依赖）
  EmbyAPI/               # Emby 网络层与 DTO            → 依赖 PrismCore
  PrismData/             # 本地缓存 / Keychain / 图片缓存 → 依赖 PrismCore, EmbyAPI
  PrismPlayback/         # 播放引擎（后续接 MPVKit）     → 依赖 PrismCore
  PrismUI/               # 设计系统与界面               → 依赖以上全部
Tests/
  PrismCoreTests/
  EmbyAPITests/
scripts/                 # env / bootstrap / build / test / run / clean
docs/                    # ROADMAP、ARCHITECTURE、BUILD_ENV、research
.github/workflows/ci.yml
```

**依赖只能自上而下**，禁止反向或环状：

```
PrismUI ──▶ PrismData ──▶ EmbyAPI ──▶ PrismCore
   └─────▶ PrismPlayback ────────────┘
```

---

## 协作者分工约定

| 目录 / 文件 | Owner | 规则 |
|---|---|---|
| `Sources/PrismCore/` | Core 代理 | 只放模型、日志、设置、工具。**不得** import SwiftUI / AppKit |
| `Sources/EmbyAPI/` | API 代理 | 只依赖 PrismCore；网络测试一律走 `URLProtocol` 桩，禁止真实网络 |
| `Sources/PrismData/` | Data 代理 | 只依赖 PrismCore + EmbyAPI |
| `Sources/PrismPlayback/` | 播放代理 | 只依赖 PrismCore；**不得** import EmbyAPI（播放地址由上层传入） |
| `Sources/PrismUI/` | UI 代理 | 唯一可以 import SwiftUI 的模块；ViewModel 不 import SwiftUI |
| `App/` | 基础设施代理 | 保持极薄：只允许 `@main`、`WindowGroup`、`Commands`、资源 |
| `Tests/<模块>Tests/` | 对应模块 owner | 每个模块一个测试 target |
| `scripts/`、`project.yml`、`Package.swift`、`.github/` | 基础设施代理 | 改动请提 issue，不要直接改 |
| `docs/research/` | 调研代理 | 其他代理只读 |
| `docs/ROADMAP.md` | 主管 | 其他代理只读 |

### 三条硬规则

1. **不要手改 `Prism.xcodeproj/project.pbxproj`**。它是生成产物，任何手改都会在下次
   `bootstrap.sh` 时被覆盖，并且必然与其他人的改动冲突。要改工程设置 → 改 `project.yml`。
2. **不要在别人的目录里写文件**。新增源文件放进自己模块的 `Sources/<模块>/` 下即可，
   SPM 按目录自动收集，无需登记。
3. **新增依赖前先问**。当前骨架刻意零第三方依赖；`Package.swift` 的 `dependencies:` 由基础设施代理统一维护。

### 提交前自检

```bash
./scripts/build.sh && ./scripts/test.sh
```

### 构建环境的三个坑（已由脚本兜住）

| 现象 | 根因 | 现状 |
|---|---|---|
| `sandbox_apply: Operation not permitted` | DSH 文件沙箱内不能再嵌套 `sandbox-exec` | `Package.swift` 统一加 `-disable-sandbox` |
| `ModuleCache ... Operation not permitted` | `~/Library/Caches`、系统 `TMPDIR` 不可写 | `scripts/env.sh` 全部重定向到 `.build/` |
| `xcodebuild: cannot open ... org.swift.swiftpm` | SwiftPM 缓存不可写 | `scripts/env.sh` 设置 `CFFIXED_USER_HOME` |

细节与排查过程见 [docs/BUILD_ENV.md](docs/BUILD_ENV.md)。

---

## 许可

TBD（播放内核使用 LGPL 版 MPVKit，分发方式见 ROADMAP）。
