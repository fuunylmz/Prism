# Prism 工程化与发布方案

> 文档类型：工程架构 / 构建 / 发布研究
> 适用产品：Prism — macOS 原生 Emby 客户端（SwiftUI + libmpv）
> 版本：v0.1（研究稿，供工程评审）
> 日期：2026-10-21
> 作者：macOS 工程化架构师
> 状态：待评审（本文档**不含任何源码改动**，仅存于 `docs/research/`）

---

## 0. 阅读指引

### 0.1 本文档解决什么问题

多智能体并行开发一个 macOS App，最大的工程风险不是「写不出功能」，而是三件事：

1. **`project.pbxproj` 合并冲突**——两个人同时加一个文件，Git 就给你一个无法自动解决的冲突块，而这个文件有上千行。
2. **并发模型失控**——Swift 6 严格并发下，一个 `Task.detached` 就能让编译器在全项目范围内报出连锁错误，而错误归属在别人的文件里。
3. **发布链路断裂**——签名顺序、公证、staple、Sparkle 更新，任何一步在最后一刻才做，都会让「能跑」变成「发不出去」。

本文档给出这三件事的工程答案，并补齐数据层、安全、CI、本地化、性能的具体配置。

### 0.2 与现有仓库基线的关系（先读这一段）

本文档**以仓库当前基线为准**，即 `docs/ARCHITECTURE.md`（冻结契约）与 `docs/ROADMAP.md` §2：

| 项目 | 仓库当前值 | 出处 |
|---|---|---|
| 部署目标 | **macOS 15.0** | `project.yml` `deploymentTarget.macOS: "15.0"`；`Package.swift` `.macOS(.v15)`；`ROADMAP` §2 |
| Swift 语言模式 | Swift 6（`swiftLanguageModes: [.v6]`） | `Package.swift` |
| 工程生成 | XcodeGen（`project.yml` 为唯一事实来源） | `ROADMAP` §4 |
| 分发 | Developer ID + notarytool + DMG + Sparkle 2 | `ROADMAP` §2 |
| 播放内核 | 纯 libmpv（MPVKit，**LGPL** 版） | `ROADMAP` §2 |

> ⚠️ **与任务书的偏差**：任务书描述的是「Xcode 模板原始状态（部署目标 27.0）」。模板已被替换为上述 15.0 基线。本文档全部按 **15.0** 书写；若最终决定改回 27.0，替换点集中在 §1.4（`project.yml`）、§1.6（`Package.swift`）、§2.6（并发配置）三处，均已逐处标注 `【27.0 时改为】`。这个决策必须在动工前定，理由见 §11 决策 D1。

### 0.3 结论摘要（TL;DR）

1. **`project.pbxproj` 必须被当成构建产物，而不是源码。** 唯一事实来源是 `project.yml`（XcodeGen），`Prism.xcodeproj` 进 `.gitignore`。这一条单独就能消灭 90% 的合并冲突。
2. **薄 App target（只有 `@main` + 资源 + entitlements）+ 根 SPM 包多 target** 是让「多人并行」变成「多包并行」的关键：每个代理只改自己 target 目录下的 `.swift`，`Package.swift` 属于受保护文件。
3. **Swift 6 并发用「默认 MainActor + 显式 actor」而非「到处 `@MainActor`」**：`PrismUI` 全模块默认 `MainActor`，`PrismCore/EmbyAPI/PrismData/PrismPlayback` 默认 `nonisolated`，I/O 边界用 `actor`。禁止裸 `Task.detached`。
4. **依赖要少到能数清**：v1.0 只允许 5 个第三方依赖（GRDB、Nuke、MPVKit、Sparkle、swift-snapshot-testing[仅测试]）。Keychain 用系统 `Security` 手写 80 行，不引第三方；日志用 `OSLog`；DI 用手写容器，不引 Factory。
5. **数据层以服务器为权威、本地为缓存**：`UserData`（已看/进度/收藏）冲突一律「服务器赢」，本地只保留 `pendingWrites` 队列重放，不做双向 CRDT。
6. **安全三条硬线**：token 只进 Keychain（`AfterFirstUnlockThisDeviceOnly`）；任何明文凭据不落盘（含日志、崩溃报告、`UserDefaults`）；ATS 只开 `NSAllowsLocalNetworking`，**永不开** `NSAllowsArbitraryLoads`。
7. **CI 用 `xcode-27` runner**（macOS 27.0.1 镜像，预装 Xcode 27.1），`swift test` 承担 80% 的测试量（无需模拟器、比 `xcodebuild test` 快数倍）。
8. **发布顺序不可颠倒**：`codesign` 由内向外逐个签（**禁用 `--deep` 签名**）→ `notarytool submit --wait` → `stapler staple` 到 `.app` 与 `.dmg` → `generate_appcast` 出 EdDSA 签名。
9. **App Store 路线当前不划算**：GPL 版 MPVKit 与 App Store 条款直接冲突（VLC 2011 年被下架即此原因）；我们用的 LGPL 版虽可动态链接分发，但 App Store 强制沙盒 + **禁止自更新** + 用户无法替换 dylib，使 LGPL 的「可替换」义务处于无判例的灰区。v1.0 明确只走直接分发（§7.7）。
10. **性能预算写死成数字**：冷启动 ≤ 800ms、首屏 ≤ 1.2s、大库滚动掉帧 < 1%、空闲常驻内存 ≤ 200MB。硬门禁放本地 `scripts/perf.sh`，CI 只做趋势监控（共享 runner 噪声大，见 §9.6）。

---

## 1. 多智能体并行开发的工程结构

### 1.1 为什么 `.pbxproj` 一定会冲突

`project.pbxproj` 是一个**扁平的、全量重写的对象图**。它没有「按文件分片」的概念，所有 target、所有文件引用、所有 build phase 都挤在同一个 `objects = { ... }` 字典里，并且用 24 位十六进制 UUID 互相引用。

一次「加一个 Swift 文件」在 pbxproj 里实际产生 **4 处改动**：

```
PBXBuildFile        ← 新增一条（文件 → build phase 的绑定）
PBXFileReference    ← 新增一条（路径 → UUID）
PBXGroup.children   ← 在所属分组里插入一个 UUID
PBXSourcesBuildPhase.files ← 在编译阶段里插入一个 UUID
```

两个代理同时各加一个文件，Git 的 diff 会在 `PBXGroup.children` 和 `PBXSourcesBuildPhase.files` 这两个**列表**上产生相邻行冲突。这类冲突**没有语义**——你无法从冲突块判断「该保留谁的 UUID」，只能人工打开 Xcode 重新加文件。更糟的是，`PBXFileSystemSynchronizedRootGroup`（Xcode 16+ 的「同步文件夹」）虽然缓解了「加文件」的问题，但**改 build setting、加 target、加 package 依赖**仍然写进同一个文件。

> 模板工程的 `objectVersion = 90` 已使用 `PBXFileSystemSynchronizedRootGroup`（见 `Prism.xcodeproj/project.pbxproj` 的 `fileSystemSynchronizedGroups`），这确实让「新增 .swift 文件」不再改 pbxproj。**但它不解决 target 数量增长、build setting 分叉、依赖变更带来的冲突**，而多智能体协作恰恰在这三件事上最活跃。

### 1.2 三层隔离：目录 → 包 → 工程

推荐的隔离模型是三层，每一层把冲突面收窄一个数量级：

| 层 | 谁在改 | 冲突面 | 冲突概率 |
|---|---|---|---|
| **L1 源文件**（`Sources/<Target>/*.swift`） | 各功能代理 | 同目录同名文件 | 低（按 ticket 分配目录） |
| **L2 包清单**（`Package.swift`、`project.yml`） | 仅 scaffold/主管 | 单文件、追加式 | 中（受保护文件 + 评审） |
| **L3 工程文件**（`Prism.xcodeproj`） | **无人**（生成产物） | 无 | **零** |

关键动作：**`Prism.xcodeproj` 不进版本库**。`.gitignore` 加一行即可：

```gitignore
# 生成产物，唯一事实来源是 project.yml
Prism.xcodeproj/
```

代价是：克隆后第一次必须先跑 `xcodegen generate`。用 `scripts/bootstrap.sh` 把这件事做成幂等的一条命令（见 §6.5）。

**为什么不干脆用 SwiftPM 单包 + `swift run` 做 App？** 因为 macOS App 需要 `Info.plist`、entitlements、`Assets.xcassets`、App Icon、Sparkle 的 XPC 服务嵌入、代码签名——这些 SwiftPM 都不管。所以「薄 App target」是必需的，它承担的就是这些「SwiftPM 表达不了的东西」，且**只有一个人（scaffold）会改它**。

### 1.3 XcodeGen vs Tuist vs 手改 pbxproj

| 维度 | 手改 `.pbxproj` | **XcodeGen** | Tuist |
|---|---|---|---|
| 版本（2026-10） | — | **2.46.0**（2026-07-16） | 持续发版（helm/CLI 双轨） |
| 许可证 | — | MIT ✅ | **非标准**（`NOASSERTION`，需人工确认条款）⚠️ |
| 输入格式 | 无（就是 pbxproj） | `project.yml` / JSON | `Project.swift`（Swift DSL） |
| 生成方式 | — | 纯文本模板 → pbxproj | 编译并执行 Swift 清单 |
| 学习成本 | 高（UUID 手工维护） | **低**（YAML，20 分钟） | 中（要懂 Tuist 的 Graph/Module 概念） |
| 生成速度 | — | 亚秒级 | 较慢（首次要编译清单） |
| 依赖管理 | 手工 | 支持 remote/local package | 支持，且有自己的 cache |
| 增量/缓存 | — | `--use-cache` | **强项**（binary cache、远程缓存） |
| 与「受保护文件」策略契合度 | 差 | **高**（YAML 可 review、可 diff） | 中（Swift 清单也是代码，可被代理"顺手改"） |
| 多代理并行 | **差**（冲突源） | **好** | 好 |
| 额外基础设施 | 无 | 无（单二进制） | 需要 Tuist 服务器才能发挥全部价值 |

**结论：选 XcodeGen。** 理由按权重排序：

1. **MIT 许可、单二进制、无服务端依赖**。Tuist 的许可是 `NOASSERTION`（GitHub 未能识别为标准 SPDX），且它的价值大头在远程缓存/服务器，对一个 5 人以下团队是过度投资。
2. **YAML 的 diff 可读**。Code Review 时，`project.yml` 的一行改动语义明确；`Project.swift` 是代码，一个代理可以「顺手」在里面写逻辑，反而更难守边界。
3. **`syncedFolder` 支持**（`projectFormat: xcode16_0` 起）。这意味着 `App/` 目录下新增文件也不需要改 yml。
4. **失败模式简单**：生成失败 = yml 写错了，报错行号明确；而手改 pbxproj 失败 = Xcode 打不开工程，且没有报错。

**XcodeGen 的两个坑（已核实）：**

- ⚠️ **`projectFormat: xcode27_0` 目前只在 main 分支，未进 2.46.0 正式版。** 我核对了 `2.46.0` tag 的 `Docs/ProjectSpec.md`，可选值为 `xcode16_3 / xcode16_0 / xcode15_3 / xcode15_0 / xcode14_0`；`xcode27_0`（objectVersion 110）与 `xcode26_3`（objectVersion 100）出现在 **unreleased 的 CHANGELOG "Next Version"** 里。所以：**在 2.46.0 上不要写 `projectFormat: xcode27_0`**，会被判为非法值（新版已把未知值改成 validation error）。用默认 `xcode16_0` 即可（生成的 `objectVersion` 与模板的 90 不同，但 Xcode 27 打开旧格式工程没有问题，升级时会提示「Convert」，选择稍后即可）。
- ⚠️ **`options.xcodeVersion` 默认是 `16.0`**，它只影响 `LastUpgradeCheck`。写 `"27.0"` 是安全的（用于消除 Xcode 的升级提示），但不要期待它改变 objectVersion。

### 1.4 推荐的 `project.yml`

这是**受保护文件**的完整草案，与仓库现状对齐（15.0 / Swift 6 / ad-hoc 本地签名）：

```yaml
# Prism — XcodeGen 工程定义
# 唯一事实来源。Prism.xcodeproj 是生成产物，不进版本库。
# 改动流程：改本文件 → ./scripts/bootstrap.sh → 提交 project.yml（不提交 xcodeproj）

name: Prism

options:
  bundleIdPrefix: app.prism
  deploymentTarget:
    macOS: "15.0"          # 【27.0 时改为】"27.0"
  createIntermediateGroups: true
  groupSortPosition: top
  generateEmptyDirectories: false
  xcodeVersion: "27.0"     # 仅影响 LastUpgradeCheck，不影响 objectVersion
  # 不要写 projectFormat: xcode27_0 —— XcodeGen 2.46.0 不认识（见 §1.3）
  defaultConfig: Debug

packages:
  # 根目录的本地 SPM 包：Package.swift 里的 5 个 library 产品都从这里出
  Prism:
    path: .

configs:
  Debug: debug
  Release: release

settings:
  base:
    SWIFT_VERSION: "6.0"
    MACOSX_DEPLOYMENT_TARGET: "15.0"   # 【27.0 时改为】"27.0"
    # Swift 6 语言模式已经隐含 complete 检查；此处显式写死，
    # 防止将来有人把 SWIFT_VERSION 降回 5.x 时静默退回 minimal。
    SWIFT_STRICT_CONCURRENCY: complete
    # App target 默认 MainActor，与 SPM 里 PrismUI 的 .defaultIsolation 对齐。
    # 只对薄壳（@main / 菜单命令）生效，核心逻辑都在 SPM target 里，各管各的。
    SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
    # 不写 SWIFT_APPROACHABLE_CONCURRENCY：它在 Swift 6 模式下是 no-op（见 §2.6），
    # 写了只会让人误以为它在起作用。
    DEAD_CODE_STRIPPING: YES
    CLANG_ENABLE_MODULES: YES
    # 我们的 build phase 里有 codesign/ditto，必须放开脚本沙箱
    ENABLE_USER_SCRIPT_SANDBOXING: NO
    # 通用二进制只在 Release 出（见下方 configs）；Debug 只编本机架构，快一倍
    ONLY_ACTIVE_ARCH: YES
    # 本地化：让 Xcode 优先使用 String Catalog
    LOCALIZATION_PREFERS_STRING_CATALOGS: YES
    SWIFT_EMIT_LOC_STRINGS: YES

targets:
  Prism:
    type: application
    platform: macOS

    sources:
      - path: App
        excludes:
          - "Info.plist"
          - "Prism.entitlements"

    dependencies:
      - package: Prism
        product: PrismUI

    settings:
      base:
        PRODUCT_NAME: Prism
        PRODUCT_BUNDLE_IDENTIFIER: app.prism.Prism
        INFOPLIST_FILE: App/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        CODE_SIGN_ENTITLEMENTS: App/Prism.entitlements
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        # 本地开发：ad-hoc。CI/Release 用 xcodebuild 参数覆盖（见 §6.2）
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"
        ENABLE_HARDENED_RUNTIME: NO   # Release 时由 CI 覆盖为 YES
        COMBINE_HIDPI_IMAGES: YES
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
        LD_RUNPATH_SEARCH_PATHS:
          - "$(inherited)"
          - "@executable_path/../Frameworks"
      configs:
        Debug:
          SWIFT_OPTIMIZATION_LEVEL: "-Onone"
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG
          ENABLE_TESTABILITY: YES
        Release:
          SWIFT_OPTIMIZATION_LEVEL: "-O"
          SWIFT_COMPILATION_MODE: wholemodule
          ENABLE_HARDENED_RUNTIME: YES
          # 通用二进制：Apple Silicon + Intel。Debug 不编，省一半时间。
          ARCHS[sdk=macosx*]: "arm64 x86_64"
          ONLY_ACTIVE_ARCH: NO

schemes:
  Prism:
    build:
      targets:
        Prism: all
    run:
      config: Debug
    profile:
      config: Release
    analyze:
      config: Debug
    archive:
      config: Release
```

**为什么没有 `PrismTests` target？** 因为测试都跑在 SPM 包里（`swift test`），不需要 Xcode 的 test target。这省掉了一整个 target 的 pbxproj 复杂度，也让 CI 快得多。UI 快照测试同样放在 SPM 包里（`swift-snapshot-testing` 支持 macOS 的 `NSView`/`NSWindow` 渲染）。**只有**当需要 XCUITest（真·端到端点击）时才加 test target——v1.0 不做。

### 1.5 推荐的目录树

与 `ROADMAP` §4 一致，此处补齐**每个目录的"谁拥有"**：

```
Prism/
├── project.yml                     # 🔒 受保护：XcodeGen 唯一事实来源
├── Package.swift                   # 🔒 受保护：根 SPM 清单
├── .gitignore                      # 🔒 受保护（含 Prism.xcodeproj/）
│
├── App/                            # 🔒 受保护：薄壳，只有 scaffold 能改
│   ├── PrismApp.swift              #   @main + WindowGroup + .commands
│   ├── AppDelegate.swift           #   NSApplicationDelegateAdaptor（Sparkle/MetricKit 需要）
│   ├── Commands/                   #   菜单命令（⌘O、⌘F、⌘,、播放控制）
│   ├── Info.plist                  #   ATS / Sparkle / 本地网络说明
│   ├── Prism.entitlements          #   沙盒权限
│   ├── Prism.entitlements.Release  #   Release 追加项（如需）
│   ├── Assets.xcassets/            #   AppIcon / AccentColor
│   └── Localizable.xcstrings       #   App 层字符串（菜单、关于）
│
├── Sources/                        # 每个 target 一个目录 = 一个所有权边界
│   ├── PrismCore/                  # 模型 · 日志 · 设置 · 工具
│   │   ├── Models/
│   │   ├── Logging/                #   OSLog Logger 门面 + signpost
│   │   ├── Settings/
│   │   ├── Events/                 #   AsyncStream 事件总线
│   │   └── DI/                     #   手写容器
│   ├── EmbyAPI/                    # 网络层 · DTO · 端点 · 鉴权
│   │   ├── Client/
│   │   ├── Endpoints/
│   │   ├── DTO/
│   │   └── Auth/
│   ├── PrismData/                  # GRDB · Keychain · 图片缓存 · 下载
│   │   ├── Database/
│   │   ├── Keychain/
│   │   ├── Images/
│   │   ├── Downloads/
│   │   └── Sync/                   #   进度上报队列
│   ├── PrismPlayback/              # MPVKit 封装 · 引擎 · 字幕 · Now Playing
│   │   ├── Engine/
│   │   ├── MPV/
│   │   └── NowPlaying/
│   └── PrismUI/                    # 设计系统 · 屏幕 · ViewModel
│       ├── DesignSystem/
│       ├── AppShell/
│       ├── Connect/
│       ├── Library/
│       ├── Detail/
│       ├── Search/
│       ├── Player/
│       ├── Settings/
│       └── Resources/
│           ├── Localizable.xcstrings
│           └── Assets.xcassets
│
├── Tests/
│   ├── PrismCoreTests/
│   ├── EmbyAPITests/
│   ├── PrismDataTests/
│   ├── PrismPlaybackTests/
│   ├── PrismUITests/
│   ├── SnapshotTests/              # 快照基线（__Snapshots__/）
│   └── Fixtures/                   # Emby JSON 样本（脱敏）
│
├── docs/
│   ├── ARCHITECTURE.md             # 🔒 冻结契约
│   ├── ROADMAP.md                  # 🔒
│   ├── BUILD_ENV.md                # 🔒 构建环境须知
│   └── research/
├── scripts/
│   ├── bootstrap.sh                # xcodegen generate + 环境检查
│   ├── build.sh
│   ├── test.sh
│   ├── lint.sh                     # swiftformat --lint + swiftlint
│   ├── release.sh                  # 签名 → 公证 → staple → DMG
│   └── appcast.sh                  # generate_appcast
├── .github/workflows/ci.yml        # 🔒 受保护
└── .swiftlint.yml / .swiftformat   # 🔒 受保护（格式即契约）
```

**所有权规则**（写进 PR 模板）：

> 一个代理只写自己 ticket 声明的目录。`project.yml`、`Package.swift`、`.github/`、`docs/ARCHITECTURE.md`、`scripts/release.sh` 属于受保护文件——只能提需求，不能直接改。

### 1.6 `Package.swift` 骨架

> ⚠️ **与仓库现状的差异**：当前 `Package.swift` 是 `// swift-tools-version: 6.0`。下面的骨架用 **6.2**，因为 `.defaultIsolation(MainActor.self)` 需要 `PackageDescription 6.2`（本机 `PackageDescription.swiftinterface` 标注为 `@available(_PackageDescription 6.2)`）。**若决定保持 6.0，请删掉 `.defaultIsolation(MainActor.self)` 这一行**，其余全部兼容。本机 Xcode 27.1 支持到 6.4，升到 6.2 无工具链障碍。

```swift
// swift-tools-version: 6.2
// 【27.0 时改为】// swift-tools-version: 6.4   （.macOS(.v27) 需要 PackageDescription 6.4）
import PackageDescription

// Prism 的本地 SPM 包：所有 Swift 源码的唯一构建入口。
// `swift build` / `swift test` 直接跑这个包；Xcode 工程只负责把 PrismUI 链进 Prism.app。
//
// 分层（依赖只能自上而下，禁止反向或同层互相引用）：
//
//     PrismUI ──▶ PrismData ──▶ EmbyAPI ──▶ PrismCore
//        │            │            │
//        └──▶ PrismPlayback ───────┘
//
// swift-tools-version 6.0 起，包内所有 target 默认使用 Swift 6 语言模式
// （= 完整数据竞争检查 + 严格并发）。用 per-target 的 swiftLanguageMode(.v5)
// 可以对单个 target 临时豁免——但本项目不允许，豁免必须走评审。

let package = Package(
    name: "Prism",
    // 有资源（.xcstrings / Assets）时 defaultLocalization 是必需的，
    // 否则 SPM 会报 "defaultLocalization is required"。
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v15)          // 【27.0 时改为】.macOS(.v27)
    ],
    products: [
        .library(name: "PrismCore",     targets: ["PrismCore"]),
        .library(name: "EmbyAPI",       targets: ["EmbyAPI"]),
        .library(name: "PrismData",     targets: ["PrismData"]),
        .library(name: "PrismPlayback", targets: ["PrismPlayback"]),
        .library(name: "PrismUI",       targets: ["PrismUI"]),
    ],
    dependencies: [
        // —— 运行时依赖：v1.0 只允许这 4 个（+ 测试 1 个）——
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/kean/Nuke", from: "13.2.0"),
        // MPVKit 只在 PrismPlayback 里出现；若不想让全包首次构建都拉 150MB+，
        // 把它拆成独立包 PrismPlaybackKit（见 §3.7）
        .package(url: "https://github.com/mpvkit/MPVKit", exact: "1.1.0-n9.0.2"),
        // Sparkle 只被 App target 用，不进 SPM 包（见 §3.6）
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing",
                 from: "1.19.6"),
    ],
    targets: [
        // —— 基础层：不依赖任何第三方，默认 nonisolated ——
        .target(
            name: "PrismCore",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),

        // —— 网络层 ——
        .target(
            name: "EmbyAPI",
            dependencies: ["PrismCore"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),

        // —— 数据层 ——
        .target(
            name: "PrismData",
            dependencies: [
                "PrismCore", "EmbyAPI",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Nuke", package: "Nuke"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),

        // —— 播放层：只依赖 PrismCore（冻结契约：不得 import EmbyAPI）——
        .target(
            name: "PrismPlayback",
            dependencies: [
                "PrismCore",
                .product(name: "MPVKit", package: "MPVKit"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),

        // —— UI 层：唯一允许 import SwiftUI 的 target ——
        .target(
            name: "PrismUI",
            dependencies: ["PrismCore", "EmbyAPI", "PrismData", "PrismPlayback"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                // 只给 UI 层开「默认 MainActor」：视图与 ViewModel 天然在主线程，
                // 显式标注会淹没在样板里。核心层保持 nonisolated，避免把 I/O 拖上主线程。
                // 需要 PackageDescription 6.2+（Xcode 26.3+）。在 6.0 清单下不可用，
                // 此时改用 Xcode 工程侧 SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor（见 §2.6）。
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),

        // —— 测试 ——
        .testTarget(name: "PrismCoreTests",     dependencies: ["PrismCore"]),
        .testTarget(name: "EmbyAPITests",       dependencies: ["EmbyAPI", "PrismCore"]),
        .testTarget(
            name: "PrismDataTests",
            dependencies: ["PrismData", "PrismCore", "EmbyAPI"]
        ),
        .testTarget(name: "PrismPlaybackTests", dependencies: ["PrismPlayback"]),
        .testTarget(
            name: "PrismUITests",
            dependencies: ["PrismUI", "PrismCore", "EmbyAPI", "PrismData"]
        ),
        .testTarget(
            name: "SnapshotTests",
            dependencies: [
                "PrismUI",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            resources: [.copy("__Snapshots__")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

**关于 `.defaultIsolation(MainActor.self)` 的可用性（已核实）：**
`PackageDescription` 里该 API 标注为 `@available(_PackageDescription 6.2)`。**仓库当前清单是 `6.0`，直接加这一行会编译不过。** 两条路：

- **A（推荐）**：清单升到 `// swift-tools-version: 6.2`（Xcode 26.3+ 支持，本机 Xcode 27.1 支持到 6.4），保留 SPM 侧声明。上面的骨架按这条写。
- **B（保守）**：清单留在 6.0，删掉该行，改在 Xcode 工程侧设 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（见 §2.6）。**但这是工程级的，会作用到所有 target**，与「核心层 nonisolated」冲突，不推荐。

### 1.7 `Package.swift` 里的资源与本地化

- `resources: [.process("Resources")]` —— `.xcstrings` 会被编译成 `.strings`/`.stringsdict` 并进入 `PrismUI_PrismUI.bundle`。**必须在 `Package` 上声明 `defaultLocalization`**，否则报错。
- SPM 生成的资源 bundle 在 App 里需要被拷贝：XcodeGen 生成工程时会自动处理 `package: product:` 依赖的资源，**但只有链接了该 product 的 target 才会拷**。薄 App target 链接了 `PrismUI`，所以 `PrismUI_PrismUI.bundle` 会进 `Contents/Resources/`。
- **不要在 SPM 里放 `Assets.xcassets` 里的 AppIcon**。App 图标必须由 App target 的 asset catalog 提供，SPM 资源 bundle 里的图标不会成为 App 图标。所以 `App/Assets.xcassets/AppIcon.appiconset` 与 `Sources/PrismUI/Resources/Assets.xcassets`（颜色/图片）是两份，各司其职。

---

## 2. Swift 6 严格并发

### 2.1 三条边界，先画清楚

Swift 6 的并发错误之所以难修，是因为「隔离域」在项目里没有显式声明，编译器只能靠推断，而推断结果散落在每个文件。所以第一件事是**声明三个域**：

```
┌─────────────────────────────────────────────────────────┐
│ ① MainActor 域（PrismUI + App）                          │
│    视图、ViewModel、导航、任何触碰 SwiftUI 的东西          │
├─────────────────────────────────────────────────────────┤
│ ② nonisolated 域（PrismCore / EmbyAPI / PrismData 接口）  │
│    纯值类型、纯函数、DTO、日志门面、设置读取               │
├─────────────────────────────────────────────────────────┤
│ ③ actor 域（I/O 实现）                                    │
│    EmbyClient、DatabaseWriter、ImagePipeline、MPVEngine   │
│    状态被串行化，跨域只传 Sendable                        │
└─────────────────────────────────────────────────────────┘
```

**规则**：跨域只传 `Sendable`；`async` 函数可以在任意域之间调用；**同步**函数不能跨域（会报 `Sending` / `Main actor-isolated ... cannot be referenced`）。

### 2.2 `@MainActor` 的边界：默认 MainActor，而不是到处标注

**推荐做法**：让 `PrismUI` 整个模块默认 `MainActor`（§1.6 的 `.defaultIsolation(MainActor.self)`），核心层保持 `nonisolated`。这样：

- UI 代码里**不再需要写 `@MainActor`**（减少 90% 的样板，也减少「漏标一个就报错」的摩擦）。
- 核心层写 `@MainActor` 反而变成**显式的、有代价的选择**，会被 Review 盯住。

需要反向豁免时用 `nonisolated`：

```swift
// ✅ UI 层里少数不该上主线程的纯计算
public struct ImageDownsampler {
    public nonisolated static func targetSize(for pixelSize: CGSize, maxPoint: CGFloat) -> CGSize
}

// ✅ 或者整个类型
public nonisolated struct ColorMath { ... }
```

**禁止清单（写进 `.swiftlint.yml` 的自定义规则或 Review checklist）：**

| 禁止 | 原因 | 正确写法 |
|---|---|---|
| `Task.detached { ... }` | 脱离结构化并发、不继承优先级与取消、极易捕获非 Sendable | `Task { }`（继承 actor 上下文）或 `withTaskGroup` |
| `DispatchQueue.main.async { }` | 与 Swift Concurrency 混用会产生不可见的顺序问题 | `await MainActor.run { }` 或 `@MainActor` 函数 |
| `@unchecked Sendable` | 关掉编译器检查，等于把并发 bug 藏起来 | 用 `actor` 或 `Mutex`（`Synchronization` 模块） |
| `nonisolated(unsafe) var` | 同上，只是更隐蔽 | 同上；只允许在 `@preconcurrency import` 的胶水层用，且必须注释说明 |
| `Task.sleep` 做轮询 | 浪费电、不可取消语义差 | `for await` 事件流，或 `AsyncStream` + `withTimeout` |
| 在 `deinit` 里 `await` | 不允许 | 用 `Task { await cleanup() }`（注意生命周期）或 `isolated deinit`（Swift 6.2+） |
| 全局可变 `static var` | 非 Sendable 全局状态 | `static let` + `actor`/`Mutex`；`@TaskLocal` 做上下文 |

**为什么禁止 `Task.detached` 而不是「慎用」**：`Task.detached` 不继承调用方的 actor 隔离、任务优先级、`TaskLocal` 值和**取消状态**。在多代理协作下，一个人写 `Task.detached` 刷新缓存，另一个人写 `Task { }` 取消刷新，两者语义不一致且编译器不报错——这是最难查的一类 bug。用 lint 规则一刀切最省事：

```yaml
# .swiftlint.yml 片段
custom_rules:
  no_detached_task:
    name: "禁止 Task.detached"
    regex: 'Task\s*\.\s*detached'
    message: "用 Task {} 或 withTaskGroup；detached 会丢失隔离/优先级/取消。见 docs/research/macos-engineering.md §2.2"
    severity: error
  no_dispatch_main:
    name: "禁止 DispatchQueue.main"
    regex: 'DispatchQueue\s*\.\s*main'
    message: "用 await MainActor.run {} 或 @MainActor 函数"
    severity: error
  no_unchecked_sendable:
    name: "禁止 @unchecked Sendable"
    regex: '@unchecked\s+Sendable'
    message: "用 actor 或 Mutex；确需豁免请加 // swiftlint:disable 并说明理由"
    severity: warning
```

### 2.3 Sendable 模型

**原则：DTO 与领域模型全部是不可变 `struct` + `let` 属性 + 值类型字段。**

```swift
// ✅ 值类型 + 全 let + 全 Sendable 字段 → 自动 Sendable，无需标注
public struct MediaItem: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let type: ItemType
    public let runTime: Ticks?
    public let imageTags: [ImageKind: String]
    public let userData: UserItemData
}

// ⚠️ 字典的 Key 必须是 Sendable & Hashable；ImageKind 是 String 枚举，OK。
```

**遇到不可 Sendable 的字段时，三种处理，优先级从高到低：**

```swift
// ① 换成值类型（最好）
public struct MediaItem {
    public let releaseDate: Date?          // 而不是 DateFormatter
    public let duration: Ticks?            // 而不是 CMTime 包装类
}

// ② 用 @Sendable 闭包隔离（回调场景）
public struct PlaybackEvents: Sendable {
    public let onStateChange: @Sendable (PlaybackState) -> Void
}

// ③ 确实需要引用类型 → 用 actor 包住，只暴露 Sendable 快照
public actor PlaybackSession {
    private var mpv: OpaquePointer          // 非 Sendable，但被 actor 隔离保护
    public func snapshot() -> PlaybackSnapshot { ... }   // 快照是 Sendable
}
```

**`@preconcurrency import` 的使用边界**：只在包裹第三方 C 库（MPVKit）时用，且**必须**集中在一个文件里，并在文件头注释说明：

```swift
// MPVKitBridge.swift
// @preconcurrency：MPVKit 的 C API 没有并发标注。所有对 mpv_* 的调用
// 都在 MPVEngine（actor）内部串行执行，不跨线程共享 handle。
@preconcurrency import MPVKit
```

### 2.4 actor 化的缓存与下载器

**缓存（图片/元数据）用 `actor` 而不是 `class + lock`：**

```swift
import Foundation

/// 内存 LRU 缓存。actor 保证串行访问；跨域只传 Sendable 的键值。
public actor MemoryCache<Key: Hashable & Sendable, Value: Sendable> {
    private var storage: [Key: Entry] = [:]
    private var order: [Key] = []          // 最近使用在末尾
    private let capacity: Int
    private let costLimit: Int
    private var currentCost = 0

    private struct Entry {
        let value: Value
        let cost: Int
        var lastAccess: ContinuousClock.Instant
    }

    public init(capacity: Int = 500, costLimit: Int = 128 * 1024 * 1024) {
        self.capacity = capacity
        self.costLimit = costLimit
    }

    public func value(for key: Key) -> Value? {
        guard var entry = storage[key] else { return nil }
        entry.lastAccess = .now
        storage[key] = entry
        touch(key)
        return entry.value
    }

    public func insert(_ value: Value, for key: Key, cost: Int) {
        if let old = storage[key] { currentCost -= old.cost }
        storage[key] = Entry(value: value, cost: cost, lastAccess: .now)
        currentCost += cost
        touch(key)
        evictIfNeeded()
    }

    public func removeAll() {
        storage.removeAll()
        order.removeAll()
        currentCost = 0
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while (storage.count > capacity || currentCost > costLimit), let oldest = order.first {
            order.removeFirst()
            if let e = storage.removeValue(forKey: oldest) { currentCost -= e.cost }
        }
    }
}
```

**下载器用 `actor` + 结构化并发 + 断点续传：**

```swift
public actor DownloadManager {
    public struct Job: Sendable, Identifiable {
        public let id: String            // itemId
        public let remoteURL: URL
        public let destination: URL
        public var bytesWritten: Int64
        public var totalBytes: Int64?
        public var state: State
        public enum State: Sendable { case queued, running, paused, failed(String), finished }
    }

    private var jobs: [String: Job] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let maxConcurrent = 2
    private let session: URLSession            // Sendable（URLSession 是 Sendable 的）

    /// 事件流：UI 通过 AsyncStream 订阅进度，不共享可变状态。
    private var continuations: [UUID: AsyncStream<[Job]>.Continuation] = [:]

    public func events() -> AsyncStream<[Job]> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
            continuation.yield(Array(jobs.values))
        }
    }

    private func removeContinuation(_ id: UUID) { continuations.removeValue(forKey: id) }

    private func broadcast() {
        let snapshot = Array(jobs.values)
        for c in continuations.values { c.yield(snapshot) }
    }

    public func enqueue(_ job: Job) {
        jobs[job.id] = job
        broadcast()
        pump()
    }

    public func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        jobs[id]?.state = .paused
        broadcast()
    }

    private func pump() {
        let running = tasks.count
        guard running < maxConcurrent else { return }
        for job in jobs.values where job.state == .queued {
            start(job)
            if tasks.count >= maxConcurrent { break }
        }
    }

    private func start(_ job: Job) {
        jobs[job.id]?.state = .running
        tasks[job.id] = Task { [weak self] in
            // 用 URLSession.bytes + 自己写文件，才能做进度与续传；
            // 或 URLSessionDownloadTask + delegate（需桥接）。
            // 此处省略实现，关键点是：Task 属于 actor，天然串行、可取消。
            await self?.finish(job.id)
        }
    }

    private func finish(_ id: String) {
        tasks[id] = nil
        jobs[id]?.state = .finished
        broadcast()
        pump()
    }
}
```

**关键点**：
- `actor` 的隔离让 `jobs` / `tasks` 不需要任何锁。
- 跨域只传 `[Job]`（`Sendable` 快照），UI 拿不到内部字典的引用。
- `Task` 在 actor 内创建，**继承 actor 隔离**，所以 `await self?.finish(...)` 是安全的；如果写成 `Task.detached`，就要自己处理隔离与取消。
- 事件用 `AsyncStream`，多个订阅者各自独立，不会因为一个消费者慢而阻塞其他人。

### 2.5 AsyncStream 事件总线

全局事件（登录态变化、服务器切换、播放进度、主题变更）用一个 `actor` 总线：

```swift
/// 应用级事件总线。
/// 设计要点：
/// 1. 每个订阅者拿到独立的 AsyncStream —— 慢消费者不会拖累别人。
/// 2. bufferingPolicy = .bufferingNewest(n)：UI 只关心最新状态，丢弃旧值。
/// 3. 总线本身无业务逻辑，事件类型是 enum（Sendable），便于穷举。
public actor EventBus {
    public enum Event: Sendable {
        case authChanged(serverID: String, userID: String?)
        case serverSwitched(serverID: String)
        case playbackProgress(itemID: String, position: Ticks)
        case libraryInvalidated(libraryID: String)
        case themeChanged
    }

    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]

    public init() {}

    /// 订阅。调用方用 `for await event in bus.subscribe()` 消费。
    /// 注意：返回的流在 Task 取消时会自动终止（onTermination）。
    public func subscribe(
        bufferingPolicy: AsyncStream<Event>.Continuation.BufferingPolicy = .bufferingNewest(16)
    ) -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(id) }
            }
        }
    }

    private func unsubscribe(_ id: UUID) { subscribers.removeValue(forKey: id) }

    public func publish(_ event: Event) {
        for c in subscribers.values { c.yield(event) }
    }
}
```

**消费侧（ViewModel）**：

```swift
@Observable
final class LibraryViewModel {
    private var task: Task<Void, Never>?

    init(bus: EventBus) {
        task = Task { [weak self] in
            for await event in await bus.subscribe() {
                guard let self else { return }
                if case .libraryInvalidated = event { await self.reload() }
            }
        }
    }

    deinit { task?.cancel() }   // ⚠️ deinit 里不能 await；cancel 是同步的，OK
}
```

**为什么不用 `NotificationCenter`**：`Notification` 的 `userInfo` 是 `[AnyHashable: Any]`，非 Sendable，在 Swift 6 下要么 `@unchecked` 要么每处强转。而且 `NotificationCenter` 的投递线程取决于发布者，在严格并发下是隐形地雷。`AsyncStream` 的类型是编译期检查的，且天然带背压策略。

**为什么不用 Combine**：Combine 的 `Publisher` 不是 `Sendable`，`@Published` 与 `@Observable` 是两套模型，混用会让「谁是状态源」变模糊。v1.0 统一 `@Observable` + `AsyncStream`。

### 2.6 工程侧的并发配置（精确值）

Xcode 的并发相关 build setting（**已从 `Swift.xcspec` 核实**）：

| Build Setting | 取值 | 说明 |
|---|---|---|
| `SWIFT_VERSION` | `6.0` | 决定语言模式 |
| `SWIFT_STRICT_CONCURRENCY` | `minimal` / `targeted` / `complete` | **仅在 `EFFECTIVE_SWIFT_VERSION` 为 4/4.2/5 时生效**（xcspec 里有 `Condition`）。Swift 6 模式下它被忽略，因为完整检查是默认。 |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | `nonisolated` / `MainActor` | 对应 `-default-isolation=MainActor`。**App target 建议设 `MainActor`**，与 SPM 的 `.defaultIsolation` 对齐。 |
| `SWIFT_APPROACHABLE_CONCURRENCY` | `YES` / `NO` | 开启 `DisableOutwardActorInference`、`GlobalActorIsolatedTypesUsability`、`InferIsolatedConformances`、`InferSendableFromCaptures`、`NonisolatedNonsendingByDefault`。**同样只在 Swift 5 模式生效**，Swift 6 下无效。 |

> 💡 模板工程里 `SWIFT_APPROACHABLE_CONCURRENCY = YES` 与 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 都写了，但 `SWIFT_VERSION = 5.0`，所以两者都生效。切到 `6.0` 后前者自动失效（无害），后者继续生效。**这就是为什么 `project.yml` 里只保留 `SWIFT_DEFAULT_ACTOR_ISOLATION`，删掉 `SWIFT_APPROACHABLE_CONCURRENCY`**——避免误以为它在起作用。

**升级路径（如果将来要从 Swift 5 迁到 6）**：`SWIFT_STRICT_CONCURRENCY` 从 `minimal → targeted → complete` 逐级提，每级修完 warning 再进下一级。本项目直接从 6.0 起步，没有这个阶段。

---

## 3. 关键依赖选型

### 3.1 选型原则：能少一个就少一个

每多一个依赖，就多一份：供应链风险、许可证审查、Swift 6 兼容性风险、CI 下载时间、升级维护成本。**Prism v1.0 的依赖预算：4 个运行时 + 1 个测试。**

| 类别 | 结论 | 是否引入 |
|---|---|---|
| 图片缓存 | **Nuke** | ✅ |
| SQLite | **GRDB** | ✅ |
| 播放 | **MPVKit（LGPL）** | ✅ |
| 更新 | **Sparkle 2** | ✅ |
| 快照测试 | **swift-snapshot-testing** | ✅（仅测试） |
| Keychain | **不引入**，手写 `Security` 封装 | ❌ |
| 日志 | **不引入**，`OSLog` | ❌ |
| 依赖注入 | **不引入**，手写容器 | ❌ |
| 网络 | **不引入**，`URLSession` + async/await | ❌ |
| 布局/状态 | **不引入**，SwiftUI + `@Observable` | ❌ |

### 3.2 图片缓存：Nuke vs Kingfisher

| 维度 | **Nuke 13.2.0** | Kingfisher 8.14.0 |
|---|---|---|
| 仓库 | https://github.com/kean/Nuke | https://github.com/onevcat/Kingfisher |
| Stars | ~8.7k | ~24.4k |
| 许可证 | **MIT** ✅ | **MIT** ✅ |
| 最低 macOS（Package.swift 实测） | **13.0** | 12.0 |
| tools-version | 6.0 | 6.2 |
| 语言模式 | 未声明 → 默认 v6 | **`swiftLanguageModes: [.v5]`** ⚠️ |
| 架构 | 分层：`Nuke`（核心）/ `NukeUI`（SwiftUI 视图）/ `NukeVideo` | 单体，`KFImage` 视图内建 |
| 磁盘缓存 | 自建 `DataCache`，可控 | 内建 |
| 平台重心 | **Apple 全平台，macOS 一等公民** | iOS 优先，macOS 次之 |
| 最新发布 | 2026-08-15 | 2026-10-17 |

**结论：Nuke。**

理由：

1. **`swiftLanguageModes: [.v5]`**。Kingfisher 8.14 在 Swift 6 工具链下仍以 Swift 5 语言模式编译。这本身不报错（依赖可以用不同语言模式），但意味着它内部存在**未经严格并发检查的状态**，跨 actor 边界时可能触发我们代码里的 `Sendable` 诊断，而且问题归属在别人的库里。Nuke 未声明 → 随 tools-version 6.0 走 v6，与我们的模式一致。
2. **分层更干净**。我们只需要 `Nuke`（核心 pipeline）+ 自己写 40 行 SwiftUI `AsyncImage` 替代品，而不是把 `NukeUI` 整个拖进来。`NukeUI` 的 `LazyImage` 与我们的设计系统（占位、渐变、错误态）不匹配，自己写更省事。
3. **macOS 一等公民**。Nuke 的 `ImageProcessors.Resize` / `ImageProcessors.Circle` 在 macOS 上行为与 iOS 一致；Kingfisher 的部分处理器在 macOS 上走 `NSImage` 分支，路径不同。
4. **可控的磁盘缓存**。离线场景要求我们能精确控制「哪些图留、哪些清」，Nuke 的 `DataCache` 允许我们用自己的 key（`itemID + imageTag`）和 TTL。

**风险**：Nuke 13 的 API 与 12 有 breaking change（`ImagePipeline.Configuration` 结构调整）。锁 `from: "13.2.0"`，升级到 14 时单独排期。

**替代方案（若想再省一个依赖）**：`URLSession` + `NSImage(data:)` + 自建 `NSCache`。代价是要自己实现：请求合并（同一 URL 并发请求去重）、优先级、取消、磁盘 LRU、ETag。约 400 行，且很容易写出 bug。**不推荐**，但这是唯一的「零依赖」退路。

### 3.3 SQLite：GRDB

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/groue/GRDB.swift |
| 版本 | **7.11.1**（2026-06-18） |
| 许可证 | **MIT** ✅ |
| tools-version | 6.1（**要求 Xcode 16.3+ / Swift 6.1+**） |
| 最低 macOS | 10.15（GRDB 7） |
| Stars | ~8.7k |

**结论：用 GRDB，不用 SQLite.swift，不用 Core Data。**

理由：

1. **Swift 6 原生**。GRDB 7 是为 Swift 6 重写的，`DatabaseQueue`/`DatabasePool` 的 `async` API 有正确的 `Sendable` 标注。`SQLite.swift` 至今没有 Swift 6 并发标注，会逼我们写 `@unchecked Sendable` 包装。
2. **`ValueObservation`**。这是 GRDB 的杀手锏：`ValueObservation.tracking { db in try Item.fetchAll(db) }` 直接给出 `AsyncSequence`，UI 层 `for await` 就能自动刷新。自己用 SQLite + 手写变更通知，工作量翻倍且容易漏。
3. **迁移系统**。`DatabaseMigrator` 的 `registerMigration` 是幂等的、有序的、可回滚的，正是离线缓存需要的。
4. **不用 Core Data**：Core Data 的并发模型（`NSManagedObjectContext` + `perform`）与 Swift 6 严格并发格格不入，且 schema 演进要靠 `.xcdatamodeld` 二进制，多人协作时是另一个冲突源。

**成本**：GRDB 的 `Package.swift` 用 `swift-tools-version:6.1`，**要求工具链 ≥ Swift 6.1**。本机 Swift 6.4 ✅，CI 的 Xcode 27.1 ✅。但如果有人用 Xcode 16.2 打开会解析失败——写进 `BUILD_ENV.md`。

**GRDB 的 SQLCipher 选项**：如果将来要加密数据库，GRDB 支持 `SQLCipher.swift`（注释掉的那几行）。v1.0 不需要——数据库里只有公开的媒体元数据与播放进度，token 在 Keychain。

### 3.4 Keychain：不引第三方

| 候选 | 状态 | 结论 |
|---|---|---|
| [kishikawakatsumi/KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess) | 8.2k stars，MIT，**最后 release v4.2.2（2021-03）**，最后 push 2024-05，55 个 open issue | ❌ 事实上停滞 |
| [dm-zharov/swift-security](https://github.com/dm-zharov/swift-security) | 318 stars，MIT，2025-12 活跃 | ◐ 可用但小众 |
| 系统 `Security.framework` | — | ✅ **推荐** |

**结论：手写 80 行封装。**

理由：Keychain 的 API 面很窄（`SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate` / `SecItemDelete`），我们只需要「按 account 存一个 token 字符串」。引入一个 2021 年后没发过版的库，为了省 80 行代码，不划算——而且它一旦在 Swift 6 下出问题，我们只能等上游。

```swift
import Foundation
import Security

/// Keychain 封装。只做一件事：按 (service, account) 存取 Data。
/// 设计要点：
/// - kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly：开机首次解锁后可读，
///   不随 iCloud 钥匙串同步到其他设备（token 不该跨设备漂移）。
/// - 不缓存 token 到内存的静态变量；调用方拿到 String 后自行持有。
/// - 所有操作是同步的（Keychain API 本身就是同步的），但很快（微秒级），
///   不构成主线程阻塞风险。若担心，用 actor 包一层。
public enum KeychainError: Error, Sendable {
    case unexpectedStatus(OSStatus)
    case dataCorrupted
}

public struct Keychain: Sendable {
    public let service: String

    public init(service: String = "app.prism.Prism.tokens") {
        self.service = service
    }

    public func set(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.dataCorrupted }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func get(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.dataCorrupted
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
```

> ⚠️ **沙盒下的 Keychain 注意事项**：沙盒 App 默认只能访问自己的 keychain access group（即 bundle ID）。**不要**设置 `kSecAttrAccessGroup`，除非配置了 `keychain-access-groups` entitlement。设置错的 group 会返回 `errSecMissingEntitlement (-34018)`。
> ⚠️ **本机验证提醒**：ad-hoc 签名（`CODE_SIGN_IDENTITY = "-"`）下 Keychain 仍可用，但每次重新签名后 keychain item 的 ACL 可能失效，开发期遇到 `errSecAuthFailed` 先怀疑签名变化。

### 3.5 日志：OSLog

**结论：用 `OSLog`，不引第三方（不用 CocoaLumberjack / SwiftyBeaver / Logging）。**

```swift
import OSLog

public enum Log {
    private static let subsystem = "app.prism.Prism"

    public static let network  = Logger(subsystem: subsystem, category: "network")
    public static let database = Logger(subsystem: subsystem, category: "database")
    public static let playback = Logger(subsystem: subsystem, category: "playback")
    public static let ui       = Logger(subsystem: subsystem, category: "ui")
    public static let sync     = Logger(subsystem: subsystem, category: "sync")
}

// 用法
Log.network.debug("GET \(url.path, privacy: .public) → \(status)")
Log.sync.info("progress flushed: \(count) items, \(elapsed, format: .fixed(precision: 2))s")
```

**要点**：
- **隐私**：`Logger` 的字符串插值默认是 `privacy: .private`（在 Console.app 里显示为 `<private>`），这正好保护 token/URL。要显示的部分显式标 `.public`。
- **`OSSignposter` 做性能区间**：
  ```swift
  let signposter = OSSignposter(logger: Log.ui)
  let state = signposter.beginInterval("LibraryScroll")
  defer { signposter.endInterval("LibraryScroll", state) }
  ```
  配合 Instruments 的 `os_signpost` 模板，能看到「首帧 → 图片加载完成」的完整时序。
- **不要**自己写文件日志（`FileHandle` + 轮转）。`OSLog` 已经持久化到 `~/Library/Logs/`，且用户可以用 Console.app 导出。自己写日志文件反而增加 I/O 与隐私风险。
- **崩溃上报**：v1.0 用 `MetricKit`（见 §9.4）+ 系统崩溃日志，不引第三方 SDK（Sentry 等会引入网络请求 + 隐私声明负担）。

### 3.6 依赖注入：手写容器 vs Factory

| 维度 | 手写容器 | Factory 3.5.0 |
|---|---|---|
| 仓库 | — | https://github.com/hmlongco/Factory |
| 许可证 | — | MIT ✅ |
| 代码量 | ~120 行 | 0（但引入一个包） |
| 能力 | 构造注入、测试替换、作用域（单例/每次新建） | 属性包装器 `@Injected`、作用域、装饰、预览注入 |
| Swift 6 | 完全可控 | 需要确认其 `Sendable` 标注（v3 已适配，但仍是外部依赖） |
| 风险 | 自己维护 | 第三方 API 变更 |

**结论：手写容器。**

理由：我们的依赖图是**静态的、小的**（约 12 个服务），不需要动态解析、不需要反射、不需要属性包装器。手写容器还能让「依赖方向」在代码里显式可见——这对多代理协作比「自动解析」更有价值（新人能一眼看出 `LibraryViewModel` 依赖谁）。

```swift
/// 应用级依赖容器。
/// 显式构造，不做运行时反射。每个字段都是协议类型，便于测试替换。
@MainActor
public final class AppContainer {
    public let settings: SettingsStore
    public let keychain: Keychain
    public let eventBus: EventBus
    public let client: EmbyClient
    public let database: AppDatabase
    public let imagePipeline: ImagePipeline
    public let downloads: DownloadManager
    public let playback: PlaybackService

    public init(settings: SettingsStore = .live) {
        self.settings = settings
        self.keychain = Keychain()
        self.eventBus = EventBus()
        self.client = EmbyClient(
            baseURLProvider: { [settings] in settings.activeServer?.baseURL },
            tokenProvider: { [keychain, settings] in
                guard let serverID = settings.activeServer?.id else { return nil }
                return try? keychain.get(serverID)
            }
        )
        self.database = try! AppDatabase(inMemory: false)   // 失败即 fatal：无法降级
        self.imagePipeline = ImagePipeline(configuration: .prism)
        self.downloads = DownloadManager()
        self.playback = PlaybackService(bus: eventBus, client: client)
    }

    /// 测试用：全内存、无网络
    public static func mock() -> AppContainer { ... }
}
```

**在 SwiftUI 里的注入方式**：用 `Environment`（`@Observable` 对象天然支持），而不是全局单例：

```swift
extension EnvironmentValues {
    @Entry var container: AppContainer = .mock()
}

@main struct PrismApp: App {
    @State private var container = AppContainer()
    var body: some Scene {
        WindowGroup { RootView().environment(\.container, container) }
    }
}
```

> `@Entry` 宏要求 **macOS 15+ 部署目标**（[官方文档](https://developer.apple.com/documentation/swiftui/entry())：iOS 18 / macOS 15 / visionOS 2 / watchOS 11 / tvOS 18 起）。当前 15.0 目标可用 ✅；若把部署目标降回 14.x，必须改回手写 `EnvironmentKey` 的五行样板。
>
> ⚠️ **`@Entry` 的默认值是个陷阱**：它要求默认值能在声明处直接构造，所以 `= .mock()` 这种「假实现」会成为**生产代码的兜底值**。一旦某处忘了 `.environment(\.container, container)`，App 不会崩，而是静默跑在 mock 上——比崩溃更难查。两条缓解：
> 1. `AppContainer` 内部持有一个 `isMock: Bool`，`mock()` 产出的实例在 `#if !DEBUG` 下 `fatalError("container 未注入")`。
> 2. 或者把 `@Entry` 声明为 `AppContainer?`，在 `RootView` 里 `guard let` 后 fatalError，让「忘记注入」在开发期立刻暴露。

### 3.7 播放：MPVKit

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/mpvkit/MPVKit |
| 版本 | **1.1.0-n9.0.2**（2026-10-07） |
| 许可证 | **LGPL-3.0**（`MPVKit`）/ **GPL-3.0**（`MPVKit-GPL`） |
| tools-version | 5.9 |
| 最低 macOS | 12.0 |
| 产品 | `MPVKit`、`MPVKit-GPL` |

**结论：用 `MPVKit`（LGPL 版）。**

**为什么 LGPL 版够用**：MPVKit README 的版本表写明 `MPVKit-GPL` 的差异是「Support samba protocol, same as old MPVKit version」。结合 `Package.swift` 看，GPL 版对应的是 `Libmpv-GPL` + `_FFmpeg-GPL` 一组 binaryTarget，即**用 `enable-gpl` 重新构建的 FFmpeg**（除 SMB 外还会带入 FFmpeg 的 GPL-only 组件，如 x264/x265 等编码器）。

Emby 客户端只需要**解码**，且走 HTTP/HTTPS，不需要 SMB、不需要 GPL-only 编码器。所以 GPL 版对 Prism **没有功能收益**，却带来整包 GPL 的传染性。这是 `ROADMAP` §2 已确认的决策，本文档复核后同意。

> ⚠️ **待确认**：GPL 版具体多出哪些编解码器，取决于 MPVKit 的构建脚本（`enable-gpl` 的具体 flag）。**不影响结论**（我们不用它），但如果将来有人提议切 GPL 版，必须先核对 `mpv.sh` 的构建参数。

**LGPL 的合规义务（必须写进 `LICENSES.md` 与「关于」页面）**：
1. **动态链接**。LGPL 要求用户能够替换库。SwiftPM 的 `binaryTarget` 提供的是 `.xcframework`，里面是**动态库**（`libmpv.dylib` 等），嵌入 `Contents/Frameworks/` —— 满足动态链接 ✅。**如果哪天改成静态链接，就违反 LGPL**，必须重新评估。
2. **提供源码获取途径**。在「关于」页给出 MPVKit 的仓库链接 + 我们构建所用的版本号，并声明「可从该地址获取对应源码」。
3. **保留版权声明**。`Contents/Resources/LICENSES/` 下放 `MPVKit-LICENSE.txt`、`FFmpeg-LICENSE.md`、`mpv-Copyright`。

**构建成本（主管实测数据，2026-10-21）**：

> MPVKit `1.1.0-n9.0.2` 的 release 共 **36 个 asset，总计 449.2 MB**。其中 `FFmpeg-all.zip` 91.4 MB、`Libavcodec.xcframework.zip` 58.3 MB、`Libmpv.xcframework.zip` 19.2 MB。**首次构建需下载约 150–200 MB**（LGPL 版的 binaryTarget 子集；不是全部 449 MB——449 MB 里还含 GPL 版与其它平台的产物）。

这带来三个工程后果：

- **CI 必须缓存 SwiftPM**。否则每次 CI 都重下 150–200 MB，单次构建多 2–4 分钟。缓存键见 §6.4。
- **本地首次 `swift build` 会慢**。`scripts/bootstrap.sh` 要提示这一点，不要让新人以为卡死了。
- **建议把播放层拆成独立包**。如果 `MPVKit` 写在根 `Package.swift` 的 `dependencies` 里，**任何人跑 `swift test` 都要先下 150MB**，哪怕他只改 UI。更好的做法：

```
Prism/
├── Package.swift                      # 根包：PrismCore/EmbyAPI/PrismData/PrismUI，不含 MPVKit
└── Packages/
    └── PrismPlaybackKit/
        └── Package.swift              # 只有这个包依赖 MPVKit
```

根包用 `.package(path: "Packages/PrismPlaybackKit")` 引用。这样：
- 播放层的编译失败不会阻塞 UI 层的开发（包边界即编译边界）。
- **可能**省掉 UI/Core 开发时的 MPVKit 下载——但这取决于 SwiftPM 是否按 target 图裁剪 artifact 下载，**我未实测**（见 §12.2 V4）。即使不省下载，也至少省掉链接与签名时间。
- **代价**：`PrismPlayback` 的源文件位置变了，与 `ROADMAP` §4 的目录树不一致，需要主管批准。

> ⚠️ **这个拆分是建议，不是定论**。如果团队认为「统一一个包」更重要（心智负担小），就保持现状，接受首次构建成本。**但必须在 `BUILD_ENV.md` 里写明「首次构建约 3–5 分钟，主要是下载 MPVKit」**，否则会被当成 bug 排查。

**替代方案（备选，记录在案）**：[AetherEngine](https://github.com/superuser404notfound/AetherEngine)（v7.44.0，2026-10-20）。它的定位是「FFmpeg demux + VideoToolbox/AVPlayer 解码」，HDR/杜比视界/Atmos 走系统能力，性能显著优于 libmpv（其 README 有实测：4K HDR HEVC 下 GPU 41mW vs libmpv 887mW，RSS 342MB vs 475MB）。许可证是 **LGPL-3.0 + App Store/DRM 例外**（明确允许 App Store 分发）。**为什么 v1.0 不选它**：它比 MPVKit 年轻得多，且 `ROADMAP` 已冻结「纯 libmpv」决策；但它是 v2.0 重评估时的首选，因为它的 App Store 例外条款打开了另一条分发路径。

### 3.8 更新：Sparkle 2

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/sparkle-project/Sparkle |
| 版本 | **2.10.0**（2026-09-13） |
| 许可证 | MIT（`LICENSE` 文件为多版权人 MIT 文本，GitHub 标为 `NOASSERTION` 是因为文件头格式，实质是 MIT）✅ |
| SPM 形态 | `binaryTarget`，下载 `Sparkle-for-Swift-Package-Manager.zip` |
| 最低 macOS（2.x Package.swift） | **12.0** |
| 沙盒支持 | ✅（Sparkle 1.x 不支持沙盒，2.x 支持） |

**结论：Sparkle 2，通过 SPM 引入到 App target（不进 SPM 包）。**

关键事实（已核实）：

- **Sparkle 的 SPM 包是 binaryTarget**，`Package.swift` 里 `platforms: [.macOS(.v12)]`。
- **工具位置**：用 SPM 引入后，`generate_keys` / `sign_update` / `generate_appcast` 在
  `../artifacts/sparkle/Sparkle/bin/`（相对 `SourcePackages/checkouts`）。
  在 CI 里用 `xcodebuild -resolvePackageDependencies` 之后，路径是
  `$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin/`。
- **沙盒必需**（见 §5.6）：`SUEnableInstallerLauncherService = YES` + `com.apple.security.temporary-exception.mach-lookup.global-name` 里加两个 `-spks` / `-spki` 服务名。
- **不要**启用 `SUEnableDownloaderService`：我们的 App 本来就有 `network.client` entitlement，启用 Downloader XPC 只会带来「release notes 回退到废弃 WebView」等副作用。

**为什么不自己写更新器**：EdDSA 签名验证、原子替换、失败回滚、delta 更新、权限提升（需要时）、沙盒下的 XPC 安装器——每一项都是坑。Sparkle 是 macOS 生态的事实标准，用它是正确的。

### 3.9 快照测试

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/pointfreeco/swift-snapshot-testing |
| 版本 | **1.19.6**（2026-09-21） |
| 许可证 | **MIT** ✅ |
| 用途 | 对 `NSView` / `NSWindow` 渲染做像素级基线比对 |

**结论：引入，但只用于「设计系统组件」与「关键屏幕」，不做全量。**

**为什么要快照测试**：多智能体并行时，A 改了一个 `Spacing` 常量，B 的布局可能整体偏移 2pt——单元测试发现不了，人眼也未必看得出。快照测试能精确捕捉这类回归。

**macOS 上的实现要点**：

```swift
import SnapshotTesting
import XCTest
@testable import PrismUI

final class PosterCardSnapshotTests: XCTestCase {
    func testPosterCard_light() {
        let view = PosterCard(item: .fixture, style: .standard)
            .frame(width: 200, height: 300)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        assertSnapshot(of: hosting, as: .image(size: CGSize(width: 200, height: 300)))
    }
}
```

**坑（务必写进测试规范）**：
1. **必须固定外观**（`.aqua` / `.darkAqua`），否则 CI 与本地结果不一致。
2. **必须固定字体渲染**。macOS 的字体平滑受 `NSFont` 抗锯齿设置影响；CI runner 与本地可能有细微差异。缓解：快照容差设为 `perceptualPrecision: 0.98`，或只对「布局结构」做断言（用 `as: .recursiveDescription`）。
3. **不要在快照里放网络图片**。用 `Image(nsImage:)` 注入固定色块。
4. **基线文件要提交**。`__Snapshots__/` 进版本库，PR 里能看到像素 diff。

### 3.10 依赖成本汇总

| 依赖 | 下载体积（估） | 编译时间（增量/全量） | 许可证义务 |
|---|---|---|---|
| GRDB 7.11.1 | ~4 MB（含 SQLite amalgamation） | 中 / 中（C 代码较多） | MIT，保留声明 |
| Nuke 13.2.0 | ~2 MB | 低 / 低 | MIT，保留声明 |
| **MPVKit 1.1.0-n9.0.2** | **150–200 MB（首次）** | — / **高**（大量 xcframework 链接） | **LGPL-3.0：动态链接 + 提供源码途径 + 保留声明** |
| Sparkle 2.10.0 | ~8 MB | 低 / 低 | MIT |
| swift-snapshot-testing 1.19.6 | <1 MB | 低 / 低 | MIT（仅测试，不分发） |

---

## 4. 数据层

### 4.1 缓存分层

```
┌──────────────────────────────────────────────────────────────┐
│ L0 内存（NSCache / actor MemoryCache）                         │
│    · 解码后的 NSImage（按显示尺寸降采样后）                     │
│    · 最近 500 个 MediaItem                                     │
│    · 生命周期：进程内                                          │
├──────────────────────────────────────────────────────────────┤
│ L1 磁盘 - 图片（Nuke DataCache）                                │
│    · ~/Library/Caches/app.prism.Prism/images/                  │
│    · key = "\(itemID)_\(imageTag)_\(width)"                    │
│    · 容量上限 2 GB，LRU 淘汰，7 天 TTL                          │
├──────────────────────────────────────────────────────────────┤
│ L2 磁盘 - SQLite（GRDB）                                        │
│    · ~/Library/Application Support/app.prism.Prism/prism.sqlite│
│    · 条目元数据 / UserData / 播放进度 / 离线索引 / 同步队列      │
├──────────────────────────────────────────────────────────────┤
│ L3 磁盘 - 离线媒体文件                                          │
│    · ~/Library/Application Support/app.prism.Prism/Downloads/  │
│    · 用户可在设置里改到外置盘（security-scoped bookmark）        │
├──────────────────────────────────────────────────────────────┤
│ L4 服务器（权威）                                               │
│    · 所有 UserData 的最终事实来源                               │
└──────────────────────────────────────────────────────────────┘
```

**沙盒下的路径**：`~/Library/Application Support/app.prism.Prism/` 与 `~/Library/Caches/app.prism.Prism/` 在沙盒内会自动重定向到 `~/Library/Containers/app.prism.Prism/Data/...`。**不要**硬编码路径，用 `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, ...)`。

### 4.2 Schema 设计草案

```sql
-- ============ 元数据 ============

CREATE TABLE server (
    id              TEXT PRIMARY KEY,          -- Emby ServerId (GUID)
    name            TEXT NOT NULL,
    base_url        TEXT NOT NULL,             -- https://emby.example.com:8920
    user_id         TEXT NOT NULL,
    user_name       TEXT NOT NULL,
    last_connected  REAL NOT NULL,             -- Unix epoch（秒，Double）
    is_active       INTEGER NOT NULL DEFAULT 0 -- 0/1，全局最多一个 1
);

-- 条目。只缓存「用户看过/浏览过」的，不做全库镜像（全库可能几十万条）。
CREATE TABLE item (
    id              TEXT NOT NULL,
    server_id       TEXT NOT NULL,
    name            TEXT NOT NULL,
    sort_name       TEXT,
    type            TEXT NOT NULL,             -- movie/series/season/episode/boxset/folder
    production_year INTEGER,
    run_time_ticks  INTEGER,                   -- 1 tick = 100ns
    overview        TEXT,
    official_rating TEXT,
    community_rating REAL,
    genres          TEXT,                      -- JSON array（低频查询，不值得建表）
    primary_image_tag   TEXT,
    backdrop_image_tag  TEXT,
    logo_image_tag      TEXT,
    series_id       TEXT,
    season_id       TEXT,
    index_number        INTEGER,               -- 集号
    parent_index_number INTEGER,               -- 季号
    series_name     TEXT,
    child_count     INTEGER,
    date_created    REAL,                      -- 服务器端创建时间，用于增量同步
    last_synced     REAL NOT NULL,             -- 本地写入时间
    PRIMARY KEY (id, server_id)
);

CREATE INDEX idx_item_series   ON item(series_id);
CREATE INDEX idx_item_type     ON item(server_id, type);
CREATE INDEX idx_item_synced   ON item(server_id, last_synced);

-- 用户数据。冲突以服务器为准（见 §4.4）。
CREATE TABLE user_data (
    item_id             TEXT NOT NULL,
    server_id           TEXT NOT NULL,
    user_id             TEXT NOT NULL,
    played              INTEGER NOT NULL DEFAULT 0,
    playback_position   INTEGER NOT NULL DEFAULT 0,   -- ticks
    play_count          INTEGER NOT NULL DEFAULT 0,
    is_favorite         INTEGER NOT NULL DEFAULT 0,
    last_played_date    REAL,
    server_updated_at   REAL,                          -- 服务器返回的 LastPlayedDate 等
    local_updated_at    REAL NOT NULL,                 -- 本地最后修改时间
    dirty               INTEGER NOT NULL DEFAULT 0,    -- 有未推送的本地修改
    PRIMARY KEY (item_id, server_id, user_id)
);

CREATE INDEX idx_user_data_resume ON user_data(server_id, user_id, playback_position)
    WHERE playback_position > 0;

-- 待推送的写操作队列（离线时积累，联网后重放）
CREATE TABLE pending_write (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id       TEXT NOT NULL,
    user_id         TEXT NOT NULL,
    item_id         TEXT NOT NULL,
    kind            TEXT NOT NULL,             -- progress / played / favorite
    payload         TEXT NOT NULL,             -- JSON
    created_at      REAL NOT NULL,
    attempts        INTEGER NOT NULL DEFAULT 0,
    last_error      TEXT
);

-- ============ 离线 ============

CREATE TABLE download (
    item_id         TEXT NOT NULL,
    server_id       TEXT NOT NULL,
    media_source_id TEXT NOT NULL,
    state           TEXT NOT NULL,             -- queued/running/paused/failed/finished
    total_bytes     INTEGER,
    bytes_written   INTEGER NOT NULL DEFAULT 0,
    local_path      TEXT,                      -- 相对 Downloads/ 的路径
    created_at      REAL NOT NULL,
    error           TEXT,
    PRIMARY KEY (item_id, server_id, media_source_id)
);

-- 下载的分片（用于断点续传与完整性校验）
CREATE TABLE download_segment (
    download_id     INTEGER NOT NULL REFERENCES download(rowid) ON DELETE CASCADE,
    index_no        INTEGER NOT NULL,
    byte_start      INTEGER NOT NULL,
    byte_end        INTEGER NOT NULL,
    completed       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (download_id, index_no)
);

-- ============ 同步元信息 ============

CREATE TABLE sync_state (
    key             TEXT PRIMARY KEY,          -- e.g. "library:abc123:lastSync"
    value           TEXT NOT NULL,
    updated_at      REAL NOT NULL
);

-- ============ 图片（可选，若不用 Nuke 的 DataCache） ============
-- 说明：v1.0 用 Nuke 的 DataCache，不建此表。
-- 若将来要「离线时也能显示已缓存图片」，再建：
-- CREATE TABLE image_cache (
--     key TEXT PRIMARY KEY, path TEXT NOT NULL, bytes INTEGER NOT NULL,
--     last_access REAL NOT NULL
-- );
```

**设计决策说明**：

1. **`item` 用 `(id, server_id)` 复合主键**。Emby 的 item id 在不同服务器间可能重复（尤其是同一个媒体库被多次导入），加 `server_id` 保证多服务器场景下不串数据。
2. **不做全库镜像**。一个 10 万条目的媒体库，全量缓存要 200MB+ 且首屏同步要几分钟。策略是「按需缓存 + 最近 N 条」：用户浏览到的页面写入 `item`，30 天未访问的条目在后台清理（但保留 `user_data`，因为「继续观看」必须离线可用）。
3. **`genres` 存 JSON 而不是关联表**。因为从不按 genre 做 JOIN（筛选是服务端 API 的事），只是显示用。
4. **`pending_write` 是单向队列**，不是 CRDT。理由见 §4.4。
5. **`download_segment`** 用于多段并发下载 + 断点续传。单段下载可以不建 segment，但 Emby 的 `Accept-Ranges` 支持多段，2 段并发能显著提升大文件速度。

### 4.3 缓存策略：TTL 与失效

| 数据 | 写入时机 | 失效条件 | 离线可用 |
|---|---|---|---|
| `item`（详情） | 打开详情页 / 列表页返回 | 30 天未访问 或 服务器 `DateCreated` 变化 | ✅（已缓存的） |
| `item`（列表页） | 列表页返回 | 5 分钟 TTL（切回前台强制刷新） | ✅ |
| `user_data` | 列表/详情返回 / 播放结束 / 手动标记 | **服务器返回即覆盖**（除 dirty 项） | ✅ |
| 图片 | 首次显示 | 7 天 TTL 或 2GB LRU | ✅ |
| 播放进度 | 每 10s + 暂停/退出 | 服务器返回即覆盖（除 dirty） | ✅ |
| 离线文件 | 用户显式下载 | 用户删除 | ✅ |

**实现要点**：
- 用 GRDB 的 `DatabaseMigrator` 管理 schema 版本：
  ```swift
  var migrator = DatabaseMigrator()
  migrator.registerMigration("v1_initial") { db in
      try db.execute(sql: Self.v1SQL)
  }
  // 后续迁移只追加，永不修改已发布的 migration
  ```
- **迁移不可回滚**：一旦用户升级到 v2 schema，降级回 v1 会崩溃。所以 App 的 `CFBundleVersion` 只能单调递增，且 Sparkle 的 appcast 不能提供降级（Sparkle 本身也不支持降级）。
- **数据库损坏的兜底**：启动时 `PRAGMA integrity_check`，失败则把 `prism.sqlite` 重命名为 `prism.sqlite.corrupt-<timestamp>` 并重建（用户丢失缓存，但 `user_data` 会在下次联网时从服务器拉回——这是「服务器权威」的额外收益）。

### 4.4 与服务器 UserData 的合并冲突

**核心原则：服务器是权威（server-authoritative），本地只做「乐观更新 + 队列重放」。**

不采用双向合并（CRDT / 向量时钟）的理由：Emby 的 `UserData` 只有 5 个字段，冲突场景极少，而 CRDT 的实现与测试成本是它的 20 倍。**用户真正在意的只有一件事：不要把我刚看的进度弄丢。**

#### 冲突矩阵

| 场景 | 本地状态 | 服务器状态 | 处理 |
|---|---|---|---|
| **A. 正常播放后上报成功** | progress=1200s, dirty=1 | 接受，progress=1200s | 清 dirty，写 `server_updated_at` |
| **B. 播放后上报失败（离线）** | progress=1200s, dirty=1 | progress=600s（旧） | **保留本地**，入 `pending_write`，UI 显示「待同步」 |
| **C. 联网后拉取，本地 dirty** | progress=1200s, dirty=1 | progress=600s | **不覆盖本地**；先推送本地，成功后以服务器回执为准 |
| **D. 联网后拉取，本地不 dirty** | progress=600s, dirty=0 | progress=1200s（另一设备看的） | **服务器覆盖本地**（这正是用户期望的「跨设备续播」） |
| **E. 本地标记已看，服务器标记未看** | played=1, dirty=1 | played=0 | 推送本地；若服务器返回 409/拒绝，以服务器为准并清 dirty |
| **F. 同一 item 在两台设备同时播放** | 两台都在推 | 服务器后写者赢 | 接受「最后写入赢」；UI 不做特殊处理（Emby 本身就是这样） |
| **G. 服务器删除条目** | 本地有缓存 | 404 | 删除本地 `item`，**保留 `user_data`**（防止误删导致进度丢失） |

#### 实现：`pending_write` 重放

```swift
public actor ProgressSyncer {
    private let db: AppDatabase
    private let client: EmbyClient

    /// 每次上报：先写本地（dirty=1），再尝试推送。推送失败不阻塞 UI。
    public func record(itemID: String, position: Ticks, played: Bool) async {
        await db.upsertUserData(itemID: itemID, position: position, played: played, dirty: true)
        await flush()
    }

    /// 重放队列。幂等：同一 item 的多次进度只保留最后一次（合并）。
    public func flush() async {
        let pending = await db.pendingWrites(limit: 50)
        for write in pending {
            do {
                try await client.reportProgress(write)
                await db.clearPendingWrite(write.id)
                await db.markClean(itemID: write.itemID)
            } catch {
                await db.bumpAttempt(write.id, error: error.localizedDescription)
                // 指数退避由调用方（定时器）控制，此处直接返回
                return
            }
        }
    }
}
```

**合并规则（关键）**：同一 `(item_id, kind=progress)` 在 `pending_write` 里**只保留最新一条**（`INSERT ... ON CONFLICT DO UPDATE`）。否则用户看 2 小时会积累 720 条进度写入，重放时把服务器打爆。

```sql
-- 在 pending_write 上加唯一约束，实现「同 item 同 kind 只留最新」
CREATE UNIQUE INDEX idx_pending_unique
    ON pending_write(server_id, user_id, item_id, kind);
-- 写入时用 UPSERT 覆盖 payload
```

**播放进度的双重保障**：
1. **每 10 秒**上报一次 `/Sessions/Playing/Progress`（在线时）。
2. **暂停 / 退出 / 切集**时立即上报 `/Sessions/Playing/Stopped` 并写本地。
3. **App 进入后台 / 系统睡眠前**，用 `NSApplication.willTerminateNotification` + `IOPMAssertion` 争取时间落盘。

**不做的事**：
- ❌ 不做「本地时间戳 vs 服务器时间戳」的字段级合并。Emby 的 `UserItemDataDto` 没有 per-field 时间戳，做了也是猜。
- ❌ 不做「删除本地 vs 删除服务器」的冲突解决。删除只在服务器做，本地跟随。
- ❌ 不在 `user_data` 里存「已看百分比」的独立字段——它由 `playback_position / run_time` 推导，存两份必然不一致。

---

## 5. 安全

### 5.1 App Sandbox entitlements（精确 key，已核对 Apple 文档）

`App/Prism.entitlements`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- ① 开启沙盒。没有这一条，其余全是摆设。 -->
    <key>com.apple.security.app-sandbox</key>
    <true/>

    <!-- ② 出站网络。Emby 客户端必需（HTTP/HTTPS 到服务器）。 -->
    <key>com.apple.security.network.client</key>
    <true/>

    <!-- ③ 用户选择的文件读写。用于「导入本地字幕」「选择下载目录」。 -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>

    <!-- ④ Downloads 目录读写。可选：如果希望下载默认落在 ~/Downloads。
         注意：这是「文件夹访问」权限，不是「用户选择」权限，
         用户无法在系统设置里单独关闭它，属于较强权限。
         若 v1.0 的下载只落在容器内，可以先不开。 -->
    <key>com.apple.security.files.downloads.read-write</key>
    <true/>

    <!-- ⑤ Sparkle 沙盒安装器所需的 mach lookup 例外（见 §5.6）。
         $(PRODUCT_BUNDLE_IDENTIFIER) 由 Xcode 自动展开。 -->
    <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
    <array>
        <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
        <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
    </array>
</dict>
</plist>
```

**四条 key 的官方语义（逐条核对过 Apple Entitlements 文档）**：

| Key | 官方描述 | 我们为什么需要 |
|---|---|---|
| `com.apple.security.app-sandbox` | "A Boolean value that indicates whether the app may use access control technology to contain damage to the system and user data if an app is compromised." | 上架/分发的基本安全姿态 |
| `com.apple.security.network.client` | "A Boolean value indicating whether your app may open outgoing network connections." | 连 Emby 服务器 |
| `com.apple.security.files.user-selected.read-write` | "A Boolean value that indicates whether the app may have read-write access to files the user has selected using an Open or Save dialog." | 导入字幕、选择下载目录 |
| `com.apple.security.files.downloads.read-write` | "A Boolean value that indicates whether the app may have read-write access to the Downloads folder." | 下载文件默认落 `~/Downloads`（可选） |

> ⚠️ **Xcode 的 build setting 与 entitlement 的对应关系**（已从 `IDESwiftPackageCore` 二进制核实）：
> `ENABLE_APP_SANDBOX`、`ENABLE_OUTGOING_NETWORK_CONNECTIONS`、`ENABLE_INCOMING_NETWORK_CONNECTIONS`、`ENABLE_USER_SELECTED_FILES`（值 `readonly`/`readwrite`）、`ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER` / `_MOVIES_FOLDER` / `_MUSIC_FOLDER` / `_PICTURE_FOLDER`（值 `""`/`readonly`/`readwrite`）。
> **但**：本工程用 `CODE_SIGN_ENTITLEMENTS = App/Prism.entitlements` 显式指定文件，**不走** build setting 自动生成。两者不要混用——混用时 Xcode 生成的 entitlements 会覆盖你的文件，导致「明明写了却没生效」。`project.yml` 里已经只保留 `CODE_SIGN_ENTITLEMENTS`，这是对的。

**不需要的权限（明确不加）**：
- ❌ `com.apple.security.network.server`：我们不是服务器。加了会让审核/用户困惑。
- ❌ `com.apple.security.files.all`：完全不需要。
- ❌ `com.apple.security.cs.disable-library-validation`：只在加载未签名第三方 dylib 时需要。MPVKit 的 xcframework 会被我们签名，不需要。
- ❌ `com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory`：除非 MPV 的某些着色器路径需要。**如果运行时报相关错误再加**，不要预防性添加（会削弱 hardened runtime）。

### 5.2 沙盒下「下载目录」的正确姿势

两条路，各有取舍：

| 方案 | entitlements | 用户体验 | 限制 |
|---|---|---|---|
| **A. 容器内下载** | 不需要额外权限 | 用户找不到文件 | 无 |
| **B. 用户选择目录** | `files.user-selected.read-write` | 首次弹 NSOpenPanel，之后靠 bookmark 免弹 | 需要 `security-scoped bookmark` |
| **C. `~/Downloads`** | `files.downloads.read-write` | 文件在「下载」里，符合直觉 | 权限较宽，且用户无法在设置里撤销 |

**推荐：默认 A（容器内），设置里提供「更改下载位置」→ 走 B。**

```swift
// 保存 security-scoped bookmark
let bookmark = try url.bookmarkData(
    options: .withSecurityScope,
    includingResourceValuesForKeys: nil,
    relativeTo: nil
)
UserDefaults.standard.set(bookmark, forKey: "downloadFolderBookmark")

// 每次访问前解析并 startAccessing
var stale = false
let url = try URL(
    resolvingBookmarkData: bookmark,
    options: .withSecurityScope,
    relativeTo: nil,
    bookmarkDataIsStale: &stale
)
guard url.startAccessingSecurityScopedResource() else { throw ... }
defer { url.stopAccessingSecurityScopedResource() }
```

> ⚠️ **`startAccessingSecurityScopedResource` 必须在同一个进程生命周期内成对调用**，且**不能跨进程**。如果下载是在 XPC/后台进程里做的，需要把 bookmark 传过去并各自 start。

### 5.3 Keychain 存 token

**三条硬规则**：

1. **token 只进 Keychain**，account = `serverID`，service = `app.prism.Prism.tokens`。
2. **`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`**：
   - `AfterFirstUnlock`：开机后用户解锁过一次即可读（支持后台刷新）。
   - `ThisDeviceOnly`：**不随 iCloud 钥匙串同步**，不随备份迁移到新设备。token 是设备绑定的，跨设备同步没有意义且增加泄露面。
3. **绝不写 `UserDefaults` / 文件 / 日志**。

**"不落盘明文凭据"的完整清单**：

| 位置 | 是否允许 | 说明 |
|---|---|---|
| Keychain | ✅ | 唯一允许存 token 的地方 |
| `UserDefaults` | ❌ | 明文 plist，`defaults read` 就能看到 |
| SQLite | ❌ | 数据库文件未加密 |
| 日志（`OSLog`） | ❌ | 默认 `privacy: .private` 会遮蔽，但**不要依赖它**——显式不要打印 |
| 崩溃报告 | ❌ | 崩溃时的寄存器/栈可能含字符串；避免把 token 放在长期存活的变量里 |
| 剪贴板 | ❌ | 除非用户显式「复制服务器地址」（那不是凭据） |
| URL query（`?api_key=`） | ❌ | 会进 `URLSession` 的日志、代理、Referer。**用 `X-Emby-Token` header** |
| 网络请求日志 | ⚠️ | 打印 URL 时用 `privacy: .public` 只打 path，不打 query |

**登录流程中的密码**：
- 密码只在内存里存在一次（`String`），用于 `POST /Users/AuthenticateByName`，请求完成后立刻置空（`var pwd = ""`，虽然 Swift 的 `String` 不可控，但至少减少生命周期）。
- **不要**把密码存 Keychain（除非做「记住密码」功能，v1.0 不做）。
- 服务器返回的 `AccessToken` 是唯一长期凭据。

**登出**：
```swift
func signOut(serverID: String) async throws {
    try? await client.logout()            // POST /Sessions/Logout，失败也继续
    try keychain.delete(serverID)         // 删 token
    try await database.purge(serverID: serverID)  // 删该服务器的缓存
}
```

### 5.4 ATS 与局域网 HTTP

**这是 Emby 客户端最容易被忽略、也最容易上线后炸掉的一条。**

Emby 服务器的典型地址是 `http://192.168.1.10:8096`（明文 HTTP + 私有 IP）。ATS 默认会拦截。

#### 事实核对（Apple 官方文档原文）

> "The `NSAllowsLocalNetworking` key controls whether App Transport Security (ATS) allows your app to connect to unqualified domains, `.local` domains, and IP addresses using IPv4 or IPv6."
> "In iOS 17, iPadOS 17, and macOS 14, ATS no longer allows connections to IP addresses by default. Add individual IP addresses and classless inter-domain routing (CIDR) ranges in the `NSExceptionDomains` dictionary."
> —— [NSAllowsLocalNetworking | Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)

**结论**：

- 从 **macOS 14 起**，ATS **默认不再允许直连 IP 地址**。所以 `http://192.168.x.x:8096` 在新系统上会被拦。
- `NSAllowsLocalNetworking = YES` 正是为此设计的开关：它允许**非限定域名、`.local` 域名、以及 IPv4/IPv6 地址**。
- `NSAllowsArbitraryLoads = YES` 是**核弹**：关闭全部 ATS，包括公网 HTTPS 强制。**绝对不要用**。

#### 正确配置

`App/Info.plist`：

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <!-- 只开这一项：允许局域网 IP / .local / 非限定域名走 HTTP。
         公网域名仍然强制 HTTPS。 -->
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

**不要**加 `NSExceptionDomains` 里的具体 IP——用户的服务器 IP 是任意的，写死没有意义。

**不要**加 `NSAllowsArbitraryLoads`。如果某个服务器是公网 HTTP（罕见但存在，比如某些 VPS 上的测试实例），应该引导用户改用 HTTPS 或走反向代理，而不是放宽全局策略。

#### 用户可感知的行为

| 服务器地址 | 结果 |
|---|---|
| `https://emby.example.com` | ✅ 正常（ATS 满足） |
| `http://192.168.1.10:8096` | ✅ 正常（`NSAllowsLocalNetworking` 放行） |
| `http://emby.local:8096` | ✅ 正常（`.local` 域名放行） |
| `http://emby.example.com`（公网明文） | ❌ 被 ATS 拦截 → UI 提示「该服务器未启用 HTTPS，请改用 https:// 或配置反向代理」 |
| `https://自签名证书` | ⚠️ 需要 `URLSessionDelegate` 里处理 `URLAuthenticationChallenge`，**且必须让用户显式确认**（不能静默信任） |

#### 自签名证书的处理（v1.0 建议）

v1.0 **不做**「信任所有证书」。做法：
1. 首次连接失败时，捕获 `NSURLErrorServerCertificateUntrusted`。
2. 弹窗说明「该服务器的证书不受系统信任」，展示证书指纹（SHA-256）。
3. 用户确认后，把指纹存进 Keychain 的「已信任指纹」列表，后续 `URLSessionDelegate` 里**只信任指纹匹配的证书**（certificate pinning）。

```swift
final class PinnedTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    // ⚠️ 这里的 @unchecked 是必要的：URLSessionDelegate 的协议方法是非隔离的，
    // 而 trustedFingerprints 需要在 delegate 队列与主线程之间共享。
    // 用锁保护，而不是靠 @unchecked 掩盖问题。
    private let lock = NSLock()
    private var trustedFingerprints: Set<String>

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        // 先让系统判定；系统不信任时才看我们的 pin 列表
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            return (.performDefaultHandling, nil)
        }
        let fingerprint = Self.sha256(of: trust)
        lock.lock()
        let trusted = trustedFingerprints.contains(fingerprint)
        lock.unlock()
        return trusted ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }
}
```

### 5.5 本地网络隐私（macOS 15+，容易漏）

**事实核对**（[TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)）：

> "Local network privacy puts people in control of which programs can interact with devices on their network. The first time a program accesses the local network, the system displays an alert asking the user to approve that access."
> macOS 支持始于 **macOS 15**。
> "Most standalone executables ... don't need the `NSLocalNetworkUsageDescription` property" —— 但**App bundle 需要**。

**这意味着**：macOS 15+ 上，Prism 第一次连 `192.168.x.x` 时，系统会弹「"Prism" 想要查找并连接到本地网络上的设备」。**如果 `Info.plist` 里没有 `NSLocalNetworkUsageDescription`，系统会静默拒绝，且 App 不会出现在「系统设置 → 隐私与安全性 → 本地网络」里，用户没有任何办法授权。**

这是真实事故模式（Plex、多个 Electron 应用都踩过）。配置：

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Prism 需要访问本地网络以发现并连接局域网内的 Emby 服务器。/ Prism needs local network access to discover and connect to Emby servers on your LAN.</string>
```

仓库当前的 `App/Info.plist` **已经有这一条** ✅。

**工程后果**：
- 首次启动**不要**在用户还没登录时就发局域网请求（会莫名弹权限框）。把发现/连接动作放在用户点击「添加服务器」之后。
- 如果用户拒绝了，后续所有局域网请求返回 `EHOSTUNREACH` / "No route to host"。UI 要给**明确的引导**（「请在 系统设置 → 隐私与安全性 → 本地网络 中允许 Prism」），而不是报「网络错误」。
- 开发期用 `127.0.0.1` 不受此限制（loopback 不算 local network），所以 fixture 测试不受影响。

### 5.6 Sparkle 沙盒集成（必须做，否则更新失败）

**事实核对**（[Sandboxing with Sparkle](https://sparkle-project.org/documentation/sandboxing/)）：

> "The Installer XPC Service is required for Sandboxed applications. This service lets Sparkle install updates outside of your application's sandbox."
> "To enable the service, you must set `SUEnableInstallerLauncherService` boolean to `YES` in your application's Info.plist."
> "To allow Sparkle to communicate to its running installer tools for sandboxed applications, you will need to add the following temporary exception to your `.entitlements` file: `com.apple.security.temporary-exception.mach-lookup.global-name` → `$(PRODUCT_BUNDLE_IDENTIFIER)-spks`, `$(PRODUCT_BUNDLE_IDENTIFIER)-spki`"

`App/Info.plist` 追加：

```xml
<!-- ===== Sparkle 2 ===== -->
<key>SUFeedURL</key>
<string>https://prism.example.com/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>（由 generate_keys 生成后填入，见 §7.5）</string>
<key>SUEnableInstallerLauncherService</key>
<true/>
<!-- 不启用 Downloader：我们已有 network.client -->
<!-- <key>SUEnableDownloaderService</key><false/> -->
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUAutomaticallyUpdate</key>
<false/>
<key>SUScheduledCheckInterval</key>
<integer>86400</integer>
```

> ⚠️ **不要加 `--deep` 签名**。Sparkle 官方明确说："Due to different code signing requirements, please do not add `--deep` to `OTHER_CODE_SIGN_FLAGS` or from custom build scripts when signing your application. This is a common source of Sandboxing errors."

---

## 6. 构建与 CI

### 6.1 本地标准命令（与 `BUILD_ENV.md` 一致）

```bash
cd /Users/fuunylmz/Prism
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cache/clang"
export TMPDIR="$PWD/.build/tmp"
mkdir -p "$TMPDIR" "$PWD/.build/cache"

# 1) 生成工程（首次 / 改 project.yml 后）
xcodegen generate

# 2) 只跑包（最快，日常开发主力）
swift build --disable-sandbox --cache-path "$PWD/.build/cache"
swift test  --disable-sandbox --cache-path "$PWD/.build/cache"

# 3) 构建 App
xcodebuild -project Prism.xcodeproj -scheme Prism -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS,arch=arm64' \
  build
```

> 📌 **`BUILD_ENV.md` §4.1 强制规则**：任何会访问 GitHub 的命令（首次 `swift build` 拉依赖、`swift package resolve`、`git clone`）**必须**加：
> ```bash
> env GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
>     GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
>     swift build --disable-sandbox --cache-path "$PWD/.build/cache"
> ```
> 否则会触发 macOS 钥匙串弹窗（**已发生真实事故**）。

### 6.2 Release 构建与归档

```bash
# 归档（Developer ID）
xcodebuild -project Prism.xcodeproj -scheme Prism -configuration Release \
  -derivedDataPath build \
  -destination 'generic/platform=macOS' \
  -archivePath build/Prism.xcarchive \
  ARCHS="arm64 x86_64" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  archive

# 导出（不重新签名，直接拿 .app）
xcodebuild -exportArchive \
  -archivePath build/Prism.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist scripts/ExportOptions.plist
```

`scripts/ExportOptions.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>TEAMIDXXXX</string>
    <key>destination</key>
    <string>export</string>
    <!-- 关键：不要 strip Swift 符号，便于崩溃符号化 -->
    <key>stripSwiftSymbols</key>
    <false/>
</dict>
</plist>
```

> 💡 **`xcodebuild -exportNotarizedApp`**（已在 `xcodebuild -help` 中核实存在）可以一步导出并公证：
> ```
> xcodebuild -exportNotarizedApp -archivePath build/Prism.xcarchive -exportPath build/export
> ```
> 但它要求 archive 里已经配好 notarytool 凭据，且错误信息不透明。**推荐还是分步做**（导出 → 手动 notarytool → staple），这样失败时能看到完整的 notary log。

### 6.3 GitHub Actions workflow 草案

**Runner 选择（已核实 `actions/runner-images`）**：

| Label | 系统 | 架构 | 预装 Xcode |
|---|---|---|---|
| `macos-26` | macOS 26 | arm64 | 26.6（默认）/ 26.5 / 26.4.1 / 26.3 / 26.2 / 26.1.1 / 26.0.1 |
| **`xcode-27`** | **macOS 27.0.1 (26A434)** | **arm64** | **27.0（默认）/ 27.1 / 27.2 beta** |
| `macos-15` | macOS 15 | arm64 | 16.x（未逐个核对，仅作参考） |

我们的部署目标是 macOS 15.0，但**工具链需要 Swift 6.4 / Xcode 27**（GRDB 要 6.1+，`.defaultIsolation` 要 6.2+，若升到 v27 平台则要 6.4）。所以选 **`xcode-27`**。注意它当前是 **preview** 状态（runner-images issue #14404），稳定性略低于正式镜像；如果 CI 不稳，回退到 `macos-26` + `DEVELOPER_DIR=/Applications/Xcode_26.6.app`（但会失去 Swift 6.4）。

`.github/workflows/ci.yml`：

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

# 同一分支的新 push 取消旧构建，省 runner 时间
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

env:
  # 统一入口，避免各 step 里重复写
  DEVELOPER_DIR: /Applications/Xcode_27.1.app/Contents/Developer
  # 【BUILD_ENV.md §4.1】禁用 git 凭据助手，避免钥匙串弹窗
  GIT_TERMINAL_PROMPT: "0"
  GIT_CONFIG_COUNT: "1"
  GIT_CONFIG_KEY_0: credential.helper
  GIT_CONFIG_VALUE_0: ""

jobs:
  # ─────────────────────────────────────────────
  # Job 1：快速反馈（不构建 App，只跑包测试 + lint）
  # ─────────────────────────────────────────────
  package:
    name: Swift Package (build + test + lint)
    runs-on: xcode-27
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4

      - name: Toolchain info
        run: |
          xcodebuild -version
          swift --version

      # SwiftPM 缓存：命中时省掉 150–200MB 的 MPVKit 下载
      - name: Cache SwiftPM
        uses: actions/cache@v4
        with:
          path: |
            .build
            ~/Library/Caches/org.swift.swiftpm
          key: spm-${{ runner.os }}-${{ hashFiles('Package.swift', 'Packages/**/Package.swift') }}
          restore-keys: |
            spm-${{ runner.os }}-

      - name: Build (Swift 6 strict concurrency)
        run: |
          swift build --disable-sandbox \
            --cache-path "$PWD/.build/cache" \
            -Xswiftc -warnings-as-errors

      - name: Test
        run: |
          swift test --disable-sandbox \
            --cache-path "$PWD/.build/cache" \
            --enable-code-coverage

      - name: Coverage summary
        run: |
          xcrun llvm-cov report \
            .build/debug/PrismPackageTests.xctest/Contents/MacOS/PrismPackageTests \
            -instr-profile .build/debug/codecov/default.profdata \
            -ignore-filename-regex='Tests/|\.build/' || true

  # ─────────────────────────────────────────────
  # Job 2：工程生成 + App 构建（验证 project.yml 与真实构建）
  # ─────────────────────────────────────────────
  app:
    name: Xcode Project (generate + build)
    runs-on: xcode-27
    timeout-minutes: 40
    steps:
      - uses: actions/checkout@v4

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Generate project
        run: xcodegen generate

      # 【关键】校验「提交的 xcodeproj」与「project.yml 生成结果」无漂移
      # 因为 xcodeproj 已被 gitignore，这一步实际上是验证 yml 能生成出可用工程
      - name: Verify generated project
        run: |
          test -d Prism.xcodeproj || { echo "xcodegen 未生成工程"; exit 1; }
          xcodebuild -project Prism.xcodeproj -list

      - name: Build app (Debug, ad-hoc signed)
        run: |
          xcodebuild -project Prism.xcodeproj -scheme Prism \
            -configuration Debug \
            -derivedDataPath build \
            -destination 'platform=macOS,arch=arm64' \
            CODE_SIGN_IDENTITY="-" \
            CODE_SIGN_STYLE=Manual \
            build

      - name: Smoke test — app launches
        run: |
          APP="build/Build/Products/Debug/Prism.app"
          test -d "$APP"
          # 校验 bundle 结构
          /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist"
          /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSAllowsLocalNetworking" "$APP/Contents/Info.plist"
          /usr/libexec/PlistBuddy -c "Print :NSLocalNetworkUsageDescription" "$APP/Contents/Info.plist"
          # 校验 entitlements 确实被签进去了
          codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox"

  # ─────────────────────────────────────────────
  # Job 3：格式与静态检查（可并行，最快失败）
  # ─────────────────────────────────────────────
  lint:
    name: Format + Lint
    runs-on: xcode-27
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
      - name: Install tools
        run: brew install swiftformat swiftlint
      - name: SwiftFormat (check only)
        run: swiftformat --lint --config .swiftformat Sources Tests App
      - name: SwiftLint
        run: swiftlint lint --strict --config .swiftlint.yml
```

### 6.4 缓存策略

| 缓存对象 | 路径 | Key | 命中收益 |
|---|---|---|---|
| SwiftPM 依赖 | `.build` + `~/Library/Caches/org.swift.swiftpm` | `hashFiles('Package.swift')` | **省 150–200 MB 下载 + 2–4 分钟** |
| Xcode DerivedData | `build/` | `hashFiles('project.yml', 'Package.resolved')` | 省增量编译（首次无用） |
| Homebrew | `~/Library/Caches/Homebrew` | 固定 key | 省 xcodegen/swiftlint 安装 |

**注意**：
- **不要缓存 `Prism.xcodeproj`**——它是生成物，缓存了会掩盖 `project.yml` 的错误。
- `Package.resolved` **必须提交**。它是依赖的锁文件，不提交会导致不同机器解析出不同版本。
- MPVKit 的 binaryTarget 缓存在 `.build/artifacts/` 里，跟着 `.build` 一起缓存即可。

### 6.5 `scripts/bootstrap.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cache/clang"
export TMPDIR="$PWD/.build/tmp"
mkdir -p "$TMPDIR" "$PWD/.build/cache"

command -v xcodegen >/dev/null || { echo "缺少 xcodegen：brew install xcodegen"; exit 1; }

echo "→ 生成 Prism.xcodeproj"
xcodegen generate

echo "→ 解析依赖（首次会下载 MPVKit，约 150–200 MB，请耐心）"
env GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
    swift package resolve --disable-sandbox --cache-path "$PWD/.build/cache"

echo "✅ 完成。打开工程：open Prism.xcodeproj"
```

### 6.6 测试金字塔

```
                    ╱╲
                   ╱  ╲        E2E / 冒烟（3–5 个）
                  ╱────╲       · App 能启动、能登录、能播放一个 fixture
                 ╱      ╲      · CI 里跑，慢，失败即阻断发布
                ╱────────╲
               ╱  快照    ╲     UI 快照（20–40 个）
              ╱            ╲    · 设计系统组件 + 关键屏幕
             ╱──────────────╲   · 像素基线，防视觉回归
            ╱    集成测试     ╲  集成（30–60 个）
           ╱                  ╲  · EmbyClient × mock server（URLProtocol）
          ╱────────────────────╲ · GRDB 迁移、缓存读写
         ╱      单元测试         ╲ 单元（200+ 个）
        ╱                        ╲· Ticks 换算、DTO 解码、合并逻辑
       ╱──────────────────────────╲· 纯函数、无 I/O、毫秒级
```

| 层 | 数量目标 | 运行时间 | 工具 | 失败处理 |
|---|---|---|---|---|
| 单元 | 200+ | < 5s | Swift Testing（`@Test`） | 阻断 |
| 集成 | 30–60 | < 30s | Swift Testing + `URLProtocol` stub | 阻断 |
| 快照 | 20–40 | < 60s | swift-snapshot-testing | 阻断（基线需人工批准） |
| E2E | 3–5 | < 5min | XCUITest（可选） | 阻断发布 |

**用 Swift Testing 而不是 XCTest**（Xcode 16+ 内建）：

```swift
import Testing
@testable import PrismCore

@Suite("Ticks 换算")
struct TicksTests {
    @Test("秒 → ticks → 秒 往返一致")
    func roundTrip() {
        let t = Ticks(seconds: 83.5)
        #expect(t.rawValue == 835_000_000)
        #expect(abs(t.seconds - 83.5) < 0.001)
    }

    @Test("格式化", arguments: [
        (0.0, "0:00"),
        (83.5, "1:23"),
        (3723.0, "1:02:03"),
    ])
    func formatting(seconds: Double, expected: String) {
        #expect(Ticks(seconds: seconds).formatted == expected)
    }
}
```

**集成测试用 `URLProtocol` 拦截，不连真服务器**（`BUILD_ENV.md` 明令：禁止把真实地址/账号写进代码或测试）：

```swift
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    // ⚠️ 这是测试代码，nonisolated(unsafe) 可接受；生产代码禁止。

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown)); return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
```

### 6.7 SwiftLint / SwiftFormat 配置

`.swiftformat`：

```
--swiftversion 6.0
--indent 4
--indentcase false
--maxwidth 110
--wraparguments before-first
--wrapparameters before-first
--stripunusedargs closure-only
--disable redundantSelf
--disable trailingCommas
--exclude .build,build,DerivedData,.spike
```

`.swiftlint.yml`：

```yaml
disabled_rules:
  - trailing_whitespace
  - todo
opt_in_rules:
  - empty_count
  - explicit_init
  - force_unwrapping      # 生产代码禁止 `!`
  - implicitly_unwrapped_optional
  - overridden_super_call
  - unowned_variable_capture

line_length:
  warning: 120
  error: 160

type_body_length:
  warning: 400
  error: 600

file_length:
  warning: 600
  error: 1000

excluded:
  - .build
  - build
  - DerivedData
  - .spike
  - Tests/Fixtures

custom_rules:
  no_detached_task:
    name: "禁止 Task.detached"
    regex: 'Task\s*\.\s*detached'
    message: "用 Task {} 或 withTaskGroup。见 docs/research/macos-engineering.md §2.2"
    severity: error
  no_dispatch_main:
    name: "禁止 DispatchQueue.main"
    regex: 'DispatchQueue\s*\.\s*main'
    message: "用 await MainActor.run {} 或 @MainActor 函数"
    severity: error
  no_unchecked_sendable:
    name: "禁止 @unchecked Sendable"
    regex: '@unchecked\s+Sendable'
    message: "用 actor 或 Mutex；确需豁免请加 swiftlint:disable 并说明理由"
    severity: warning
```

> ⚠️ `force_unwrapping` 在测试代码里会很烦。用 `Tests/` 目录的 `.swiftlint.yml` 覆盖（SwiftLint 支持嵌套配置），或在测试文件头 `// swiftlint:disable force_unwrapping`。

### 6.8 构建产物导出

| 产物 | 用途 | 生成方式 |
|---|---|---|
| `Prism.xcarchive` | 归档备份、符号化 | `xcodebuild archive` |
| `Prism.app` | 可直接运行 | `xcodebuild -exportArchive` |
| `Prism-<ver>.dmg` | 分发 | `create-dmg` 或 `hdiutil`（§7.3） |
| `Prism-<ver>.zip` | Sparkle 更新包 | `ditto -c -k --sequesterRsrc --keepParent` |
| `Prism.app.dSYM` | 崩溃符号化 | archive 内 |
| `appcast.xml` | Sparkle 更新源 | `generate_appcast`（§7.5） |

---

## 7. 分发

### 7.1 完整发布流水线

```
① 归档（xcodebuild archive, Release, universal, hardened runtime）
        ↓
② 签名校验（由内向外逐个验证，不用 --deep 签）
        ↓
③ 打包 DMG（hdiutil / create-dmg）
        ↓
④ 公证（notarytool submit --wait）
        ↓
⑤ 检查 notary log（即使 Accepted 也要看 warning）
        ↓
⑥ staple 到 .app 与 .dmg
        ↓
⑦ 验证（spctl -a -t exec -vv + stapler validate）
        ↓
⑧ 生成 Sparkle 更新包（ditto → zip）
        ↓
⑨ generate_appcast（EdDSA 签名）
        ↓
⑩ 上传（DMG + zip + appcast.xml）
```

### 7.2 签名：由内向外，禁用 `--deep`

**Apple 官方立场**（[TN2206: macOS Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)）：

> "While the `--deep` option can be applied to a signing operation, this is not recommended. We recommend that you sign code inside out in individual stages (as Xcode does automatically). Signing with `--deep` is for emergency repairs and temporary adjustments only."

**所以**：`--deep` **只用于验证**（`codesign --verify --deep --strict`），**不用于签名**。

签名顺序（每一层都签，从最内层开始）：

```bash
#!/usr/bin/env bash
# scripts/sign.sh —— 对已导出的 .app 做完整的 Developer ID 签名
set -euo pipefail

APP="$1"
IDENTITY="Developer ID Application: Your Name (TEAMIDXXXX)"
ENTITLEMENTS="App/Prism.entitlements"

sign() {
  echo "  → $1"
  /usr/bin/codesign --force --sign "$IDENTITY" \
    --options runtime \
    --timestamp \
    "$@" 2>&1 | sed 's/^/     /'
}

echo "① 签名内嵌的 dylib / framework（由内向外）"

# MPVKit 的 xcframework 会在 Frameworks/ 下展开成多个 .framework
if [ -d "$APP/Contents/Frameworks" ]; then
  # 先签所有 .dylib
  find "$APP/Contents/Frameworks" -type f -name "*.dylib" -print0 |
    while IFS= read -r -d '' lib; do
      sign "$lib"
    done

  # 再签所有 .framework（framework 是 bundle，要整体签）
  find "$APP/Contents/Frameworks" -type d -name "*.framework" -print0 |
    while IFS= read -r -d '' fw; do
      # 如果 framework 里有 XPCServices，先签 XPC
      if [ -d "$fw/Versions/B/XPCServices" ]; then
        find "$fw/Versions/B/XPCServices" -type d -name "*.xpc" -print0 |
          while IFS= read -r -d '' xpc; do
            sign --preserve-metadata=entitlements "$xpc"
          done
      fi
      sign "$fw"
    done
fi

echo "② 签名 App 主 bundle（带 entitlements）"
/usr/bin/codesign --force --sign "$IDENTITY" \
  --options runtime \
  --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "$APP"

echo "③ 验证（这一步才用 --deep）"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/spctl -a -t exec -vv "$APP"

echo "✅ 签名完成"
```

**几个关键点**：

1. **`--options runtime`** = 启用 Hardened Runtime。**公证强制要求**。
2. **`--timestamp`** = 安全时间戳。**公证强制要求**（"Include a secure timestamp with your code-signing signature"）。
3. **`--entitlements` 只给主 bundle**。给 dylib/framework 加 entitlements 会出错（它们不声明权限，继承宿主）。
4. **Sparkle 的 XPC 服务**用 `--preserve-metadata=entitlements`（Sparkle 官方给的做法），因为 `Downloader.xpc` 有自己的 entitlements。
5. **不用 `--deep` 签名**。原因见上。
6. **Xcode 的 `-exportArchive` 已经做了大部分签名**。如果完全信任 Xcode 的导出流程，`sign.sh` 可以只做校验。但**当 MPVKit 的 dylib 是手动拷贝进来的时候**（非 Xcode 管理的 embed），必须自己签。

> 💡 **为什么 MPVKit 需要特别关注**：SwiftPM 的 `binaryTarget` 在 Xcode 里会被当作 `Embed & Sign` 处理，Xcode 会自动签名。但**如果签名失败或顺序错了**，公证会报 `The signature of the binary is invalid`，且 notary log 会指出具体路径（`in subcomponent: ...`）。所以 §7.4 的「检查 notary log」不是可选项。

### 7.3 DMG 打包

**方案 A：`hdiutil`（零依赖，推荐用于 CI）**

```bash
#!/usr/bin/env bash
# scripts/make-dmg.sh
set -euo pipefail
APP="$1"; VERSION="$2"; OUT="$3"

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # 拖拽安装的视觉提示

# UDZO = zlib 压缩，兼容性最好
# 若追求更小体积可用 ULFO（lzfse），但需要 macOS 10.11+ 才能挂载
hdiutil create \
  -volname "Prism" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  -fs HFS+ \
  "$OUT/Prism-$VERSION.dmg"

rm -rf "$STAGING"
```

> 💡 **格式选择**：Sparkle 文档建议 "APFS formatted images that use lzfse compression are recommended for decent decompression speed"。`hdiutil` 对应的是 `-fs APFS -format ULFO`。但 **APFS 格式的 DMG 在 macOS 15 以下无法挂载**——我们的部署目标是 15.0，所以 APFS 安全。若将来要支持更老系统，退回 `HFS+` + `UDZO`。

**方案 B：`create-dmg`（有背景图、图标布局，更"正式"）**

```bash
brew install create-dmg
create-dmg \
  --volname "Prism" \
  --volicon "App/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" \
  --background "scripts/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "Prism.app" 180 170 \
  --hide-extension "Prism.app" \
  --app-drop-link 480 170 \
  "Prism-$VERSION.dmg" \
  "build/export/"
```

**取舍**：CI 里用 `hdiutil`（不依赖 Homebrew、可控），本地做「正式版」时用 `create-dmg`（好看）。**两者产出的 DMG 都要公证 + staple**。

### 7.4 公证（notarytool）

**事实核对**（[Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)）：

> "The `altool` command has been deprecated, and the Apple notary service no longer supports `altool` from November 1, 2023."

**所以：只用 `notarytool`，`altool` 已死。**

#### 一次性配置凭据

```bash
# 方式 A：App Store Connect API Key（推荐 CI 用，可撤销、不绑 2FA）
xcrun notarytool store-credentials "prism-notary" \
  --key "/path/to/AuthKey_XXXXXXXXXX.p8" \
  --key-id "XXXXXXXXXX" \
  --issuer "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

# 方式 B：Apple ID + App 专用密码（个人开发者常用）
xcrun notarytool store-credentials "prism-notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMIDXXXX" \
  --password "xxxx-xxxx-xxxx-xxxx"   # App 专用密码，不是账号密码
```

> ⚠️ **App 专用密码**在 https://appleid.apple.com 生成，**不是**账号登录密码。CI 里用 `--keychain-profile` 从 Keychain 读，**不要**把密码写进环境变量（会进 CI 日志）。

#### 提交

```bash
xcrun notarytool submit "Prism-1.0.0.dmg" \
  --keychain-profile "prism-notary" \
  --wait \
  --output-format json | tee notary-result.json

# 提取 submission id
SUBMISSION_ID=$(python3 -c "import json;print(json.load(open('notary-result.json'))['id'])")
STATUS=$(python3 -c "import json;print(json.load(open('notary-result.json'))['status'])")

if [ "$STATUS" != "Accepted" ]; then
  xcrun notarytool log "$SUBMISSION_ID" \
    --keychain-profile "prism-notary" \
    notary-log.json
  cat notary-log.json
  exit 1
fi
```

**参数说明（已从 `notarytool submit --help` 核实）**：

| 参数 | 说明 |
|---|---|
| `--wait` | 阻塞直到处理完成，返回最终状态。**CI 必用** |
| `--keychain-profile <name>` | 用 `store-credentials` 存好的凭据 |
| `--apple-id` / `--password` / `--team-id` | 直接给凭据（不推荐，会进 shell history） |
| `--key` / `--key-id` / `--issuer` | API Key 方式 |
| `--output-format json` | 便于脚本解析 |
| `--webhook <url>` | 异步通知（CI 里用 `--wait` 更简单） |

**公证什么？** 提交 **DMG**（不是 .app）。Apple 会递归公证里面的 .app。也可以提交 .zip，但**zip 不能 staple**（"While you can notarize a ZIP archive, you can't staple to it directly"），所以**优先公证 DMG**。

#### staple

```bash
# 先 staple 到 .app（这样即使用户把 app 拖出 dmg 也带着票据）
xcrun stapler staple "build/export/Prism.app"
# 再重新打 DMG（因为 .app 变了）
./scripts/make-dmg.sh "build/export/Prism.app" "$VERSION" "build"
# 再公证 + staple DMG
xcrun notarytool submit "build/Prism-$VERSION.dmg" --keychain-profile "prism-notary" --wait
xcrun stapler staple "build/Prism-$VERSION.dmg"
xcrun stapler validate "build/Prism-$VERSION.dmg"
```

> ⚠️ **顺序陷阱**：如果先公证 DMG、再 staple .app，DMG 里的 .app 就变了，DMG 的票据失效。**正确顺序是：公证 .app → staple .app → 打 DMG → 公证 DMG → staple DMG。** 这会导致两次公证（约 2×3 分钟），但这是唯一正确的顺序。
>
> **优化**：也可以只公证 DMG、只 staple DMG（不 staple .app）。这样只需一次公证，但用户如果把 .app 拖出 DMG 再传到没网的地方，Gatekeeper 会去在线查票据。**推荐做两次**，代价可接受。

### 7.5 Sparkle appcast

#### 生成密钥（一次性）

```bash
# 工具在 SPM artifacts 里
SPARKLE_BIN="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"

"$SPARKLE_BIN/generate_keys"
# 输出：
#   A key has been generated and saved in your keychain. Add the `SUPublicEDKey` key to
#   the Info.plist of each app ...
#       <key>SUPublicEDKey</key>
#       <string>pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ=</string>
```

- **私钥存在登录钥匙串**里，`generate_keys` 不会打印它。
- 把公钥填进 `App/Info.plist` 的 `SUPublicEDKey`。
- **备份私钥**：`generate_keys -x private-key-file` 导出，`-f` 导入。**丢了私钥 = 老用户永远收不到更新**（除非做 key rotation，而 rotation 要求 Developer ID 证书也一起换）。

#### 生成 appcast

```bash
#!/usr/bin/env bash
# scripts/appcast.sh —— 在包含所有历史版本的目录上运行
set -euo pipefail
SPARKLE_BIN="$1"        # .../artifacts/sparkle/Sparkle/bin
ARCHIVE_DIR="$2"        # 放着 Prism-1.0.0.dmg, Prism-1.0.1.dmg ... 和 release notes
DOWNLOAD_URL_PREFIX="$3" # https://prism.example.com/releases/

"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --link "https://prism.example.com" \
  --embed-release-notes \
  "$ARCHIVE_DIR"
```

产出 `appcast.xml`，形如：

```xml
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Prism</title>
    <item>
      <title>Version 1.0.0</title>
      <pubDate>Mon, 20 Oct 2026 10:00:00 +0000</pubDate>
      <sparkle:version>1</sparkle:version>
      <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://prism.example.com/releases/Prism-1.0.0.dmg"
        sparkle:edSignature="7cLALFUHSwvEJWSkV8aMreoBe4fhRa4FncC5NoThKxwThL6FDR7hTiPJh1fo2uagnPogisnQsgFgq6mGkt2RBw=="
        length="18234567"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
```

> 💡 `sparkle:minimumSystemVersion` **必须是三段式**（`15.0.0`，不是 `15.0`）。官方文档："be sure to specify a three-part version in form of major.minor.patch"。

#### 更新渠道

Sparkle 2 的 channel 机制（官方文档已核实）：

```xml
<item>
  <title>Version 1.1.0-beta.1</title>
  <sparkle:channel>beta</sparkle:channel>
  <sparkle:version>110</sparkle:version>
  <sparkle:shortVersionString>1.1.0-beta.1</sparkle:shortVersionString>
  ...
</item>
```

客户端：

```swift
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // 用户在设置里勾了「加入 Beta 计划」才订阅 beta 渠道
        UserDefaults.standard.bool(forKey: "PrismBetaChannel") ? ["beta"] : []
    }
}
```

**三条渠道规则**：
1. **默认渠道（stable）** 永远只放正式版。
2. **beta 渠道** 放预发布版，用户显式 opt-in。
3. **critical 更新**（安全修复）用 `<sparkle:criticalUpdate>`，用户不能跳过。

### 7.6 版本号规则

| 字段 | 含义 | 规则 | 示例 |
|---|---|---|---|
| `CFBundleShortVersionString` / `MARKETING_VERSION` | 用户可见版本 | **语义化** `MAJOR.MINOR.PATCH` | `1.2.0` |
| `CFBundleVersion` / `CURRENT_PROJECT_VERSION` | 机器可读构建号 | **单调递增整数**，永不复用 | `1023` |
| Sparkle `sparkle:version` | 对应 `CFBundleVersion` | 必须是整数 | `1023` |
| Sparkle `sparkle:shortVersionString` | 对应 `CFBundleShortVersionString` | 给用户看 | `1.2.0` |
| Git tag | 发布标记 | `v1.2.0` | `v1.2.0` |

**生成规则**：`CFBundleVersion = MAJOR * 10000 + MINOR * 100 + PATCH`（`1.2.0` → `10200`）。好处是可读、可比较、不会撞。

> ⚠️ **绝对不要**用 `git rev-list --count HEAD` 做 `CFBundleVersion`——Sparkle 官方明确说 "the internal version number (CFBundleVersion and sparkle:version) is intended to be machine-readable and is not generally suitable for formatted text or git changeset IDs"。

### 7.7 App Store 路线的差异点（明确写清）

**结论：v1.0 不走 App Store。** 不是"麻烦"，是**三处硬冲突**。

#### 冲突 1：GPL 组件

如果使用 `MPVKit-GPL`（含 libsmbclient 等 GPL 组件），整个 App 变成 GPL 衍生作品。GPL 要求用户有「再分发」的自由，而 App Store 的使用条款限制这一点。

**历史证据**：
- 2011-01：Apple 因 GPL 争议下架 iOS 版 VLC（[Ars Technica](http://arstechnica.com/apple/2011/01/vlc-for-ios-vanishes-2-months-after-eruption-of-gpl-dispute)）。
- 2011-10：VideoLAN 把引擎部分从 GPL-2.0 改为 LGPL-2.1，2013-07 以 MPL-2.0 重新上架 App Store（[Wikipedia: VLC media player](https://en.wikipedia.org/wiki/VLC_media_player)）。

**注意**：**我们用的是 LGPL 版 `MPVKit`，不是 GPL 版**，所以这一条对 Prism 不直接适用。但 LGPL 有它自己的 App Store 问题（见下）。

#### 冲突 2：LGPL 与 App Store 的 DRM/签名条款

LGPL-3.0 要求用户能「替换库」。App Store 的 FairPlay DRM + Apple 独占重签名，技术上让用户无法替换 `libmpv.dylib`。

- **直接分发**：用户可以解包、替换 dylib、重新签名 → 满足 LGPL ✅
- **App Store**：用户不能 → 有争议 ⚠️

这一条在法律上有讨论空间（"mere aggregation" vs "derivative work"），但**没有判例**。风险不值得承担。

> 💡 **对比**：AetherEngine 采用 **LGPL-3.0 + App Store/DRM 例外**，在许可证里**显式授予** App Store 分发权。这解释了为什么 Sodalite 等 App Store 上的 Jellyfin 客户端能用它。**如果 Prism 将来想上 App Store，切换到 AetherEngine 是唯一低风险路径**（见 §3.7）。

#### 冲突 3：沙盒限制

| 限制 | 直接分发 | App Store |
|---|---|---|
| 沙盒 | 可选（我们主动开） | **强制** |
| `com.apple.security.temporary-exception.*` | 允许（Sparkle 需要） | **基本不允许**（临时例外需特批） |
| 自更新（Sparkle） | ✅ | **不允许**（见下方 2.5.2 原文） |
| 加载第三方 dylib | ✅ | 受限（需 `disable-library-validation`，审核严格） |
| 网络（局域网 HTTP） | ✅ `NSAllowsLocalNetworking` | ✅ 同样可以 |
| 文件系统 | 用户选择即可 | 同样 |

**关键点：App Review Guidelines 2.5.2 的原文**（已抓取 [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) 核实）：

> "Apps should be self-contained in their bundles, and may not read or write data outside the designated container area, nor may they download, install, or execute code which introduces or changes features or functionality of the app, including other apps."

这句话**没有出现「自动更新」四个字**，但「不得下载、安装或执行会引入或改变 App 功能的代码」在实务上覆盖了 Sparkle 这类自更新机制：Sparkle 下载的是**新版本的完整 App**，必然改变功能。这就是 App Store 上见不到 Sparkle 的原因（不是明文禁止，而是条款解释下的不可行）。

**推论**：上 App Store 就必须移除 Sparkle，更新只能走 App Store。这对「快速修 bug」是重大限制。

#### 如果将来要上 App Store，需要改什么

1. 播放引擎换成 **AetherEngine**（LGPL + App Store 例外），或自研基于 AVPlayer + VideoToolbox 的方案（放弃 MKV/ASS 全格式）。
2. 移除 Sparkle，改用 App Store 更新。
3. 确认没有 `temporary-exception` entitlements。
4. 通过 App Review 的「媒体播放器」审核（需要说明不侵犯版权、不提供盗版内容入口）。

**这是一个独立的产品决策，不是工程细节。** v1.0 明确不做。

---

## 8. 本地化

### 8.1 String Catalog（`.xcstrings`）

**结论：用 String Catalog，不用 `.strings` / `.stringsdict`。**

`.xcstrings` 是 JSON 格式的单一文件，Xcode 16+ 默认。相比传统 `.strings`：

- **一个文件管所有语言**（不用 20 个 `zh-Hans.lproj/Localizable.strings`）。
- **自动提取**：编译时 `SWIFT_EMIT_LOC_STRINGS = YES` 会把代码里的 `String(localized:)` 抽进 catalog。
- **复数规则内建**（不用手写 `.stringsdict`）。
- **可 review**：JSON diff 比 `.strings` 的二进制 plist 友好得多。

**工程配置**（`project.yml` 已有）：

```yaml
LOCALIZATION_PREFERS_STRING_CATALOGS: YES
SWIFT_EMIT_LOC_STRINGS: YES
STRING_CATALOG_GENERATE_SYMBOLS: YES   # 生成类型安全的符号
```

`STRING_CATALOG_GENERATE_SYMBOLS = YES` 是关键——它把 catalog 里的 key 生成成 Swift 符号：

```swift
// 自动生成（不需要手写）
Text(.libraryTitle)              // 而不是 Text("library.title")
```

这样**拼错 key 会编译失败**，而不是运行时显示 `library.titel`。多智能体协作时，这能省掉大量「key 对不上」的 bug。

### 8.2 中英双语

**`Package.swift` 必须声明 `defaultLocalization`**（已核实：有本地化资源时不声明会报错）：

```swift
let package = Package(
    name: "Prism",
    defaultLocalization: "zh-Hans",   // 开发语言
    ...
)
```

**两份 catalog**：
- `App/Localizable.xcstrings` —— App 层字符串（菜单、关于、Sparkle 更新提示）。
- `Sources/PrismUI/Resources/Localizable.xcstrings` —— UI 层字符串（绝大多数）。

**为什么分两份**：SPM 的资源 bundle 与 App target 的 catalog 是两个独立的命名空间。混在一起会导致「UI 里的 key 在 App 里找不到」。

**`Info.plist` 的本地化**：
- `CFBundleDevelopmentRegion` 设为 `zh-Hans`（当前是 `zh_CN`，建议改为 `zh-Hans`，因为 `zh_CN` 是旧式 region 标识）。
- 需要本地化的 Info.plist 字符串（如 `NSLocalNetworkUsageDescription`）用 `InfoPlist.xcstrings`。

**当前 `Info.plist` 的做法**（把中英写在同一个字符串里）**不推荐**：

```xml
<!-- ❌ 现状 -->
<string>Prism 需要访问本地网络.../ Prism needs local network access...</string>
```

**正确做法**：

```xml
<!-- ✅ Info.plist -->
<string>NSLocalNetworkUsageDescription</string>  <!-- 只放一个 key，值由 InfoPlist.xcstrings 提供 -->
```

```json
// App/InfoPlist.xcstrings
{
  "sourceLanguage" : "zh-Hans",
  "strings" : {
    "NSLocalNetworkUsageDescription" : {
      "localizations" : {
        "zh-Hans" : { "stringUnit" : { "state" : "translated",
          "value" : "Prism 需要访问本地网络以连接局域网内的 Emby 服务器。" } },
        "en" : { "stringUnit" : { "state" : "translated",
          "value" : "Prism needs local network access to connect to Emby servers on your LAN." } }
      }
    }
  },
  "version" : "1.0"
}
```

### 8.3 代码里的本地化写法

```swift
// ✅ 用 String(localized:) —— 会被自动提取
Text(String(localized: "library.title", defaultValue: "媒体库", comment: "侧边栏一级导航"))
Button(String(localized: "action.play", defaultValue: "播放")) { play() }

// ✅ 带参数（用插值，不要字符串拼接）
Text(String(localized: "detail.episodeCount \(count)",
            defaultValue: "\(count) 集"))

// ✅ 复数（在 .xcstrings 里配置 plural，代码只传数字）
Text(String(localized: "library.itemCount \(count)"))

// ❌ 不要这样
Text("媒体库")                      // 不会进 catalog，无法翻译
Text("共 " + String(count) + " 集")  // 语序无法适配英文
```

### 8.4 日期 / 数字 / 时长格式化

**用 `FormatStyle`，不用 `DateFormatter`**：

```swift
// ✅ 日期
Text(date, format: .dateTime.year().month().day())          // 跟随系统区域
Text(date, format: .relative(presentation: .named))         // "昨天" / "2 天前"

// ✅ 数字
Text(count, format: .number)                                // 1,234 / 1 234
Text(rating, format: .number.precision(.fractionLength(1))) // 8.5

// ✅ 时长（这是 Emby 客户端的核心显示）
// Ticks → "1:23:45" / "23:45"
public var formatted: String {
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d", m, s)
}
```

> ⚠️ **时长不要用 `DateComponentsFormatter`**。它会把 `1:23:45` 显示成 `1 hour, 23 minutes, 45 seconds`（太长），且受 locale 影响。**播放器时间轴需要固定格式**，用 `String(format:)` 手写。

**尺寸 / 字节**：

```swift
Text(bytes, format: .byteCount(style: .file))   // "1.2 GB"
```

**排序**：不要用 `<` 比较字符串，用 `localizedStandardCompare`：

```swift
items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
```

### 8.5 本地化检查清单（CI 可自动化）

```bash
# 1) 检查 .xcstrings 是否有未翻译的条目
python3 - <<'PY'
import json, sys, pathlib
bad = 0
for p in pathlib.Path(".").rglob("*.xcstrings"):
    data = json.loads(p.read_text())
    for key, entry in data.get("strings", {}).items():
        locs = entry.get("localizations", {})
        for lang in ("zh-Hans", "en"):
            unit = locs.get(lang, {}).get("stringUnit", {})
            if unit.get("state") != "translated":
                print(f"未翻译: {p} :: {key} :: {lang}")
                bad += 1
sys.exit(1 if bad else 0)
PY

# 2) 检查硬编码中文（排除注释与 catalog）
grep -rn --include="*.swift" -P '"[^"]*[\x{4e00}-\x{9fff}][^"]*"' Sources App \
  | grep -v "//" | grep -v "\.xcstrings" || echo "无硬编码中文 ✅"
```

---

## 9. 性能与可观测性

### 9.1 性能预算（写进 CI）

| 指标 | 目标 | 测量方式 | 超标处理 |
|---|---|---|---|
| **冷启动到首帧** | ≤ 800 ms | `OSSignposter` + Instruments | CI 红灯 |
| **首屏内容可见** | ≤ 1.2 s（本地网络） | 同上 | CI 警告 |
| **大库滚动** | 120 Hz，掉帧 < 1% | Instruments 的 Animation Hitches | CI 红灯 |
| **常驻内存（空闲）** | ≤ 200 MB | `task_info` / Instruments | CI 警告 |
| **常驻内存（4K 播放）** | ≤ 900 MB | 同上 | 人工评审 |
| **图片缓存命中率** | ≥ 85% | 自建计数器 | 周报 |
| **App 体积（DMG）** | ≤ 250 MB | `du -sh` | 人工评审 |
| **数据库查询 P95** | ≤ 5 ms | GRDB trace | CI 警告 |

> 💡 **App 体积的现实预期**：MPVKit 的 xcframework 链接后约 60–90 MB（universal），加上资源约 120 MB，DMG 压缩后约 60–80 MB。**250 MB 的预算是宽松的**，主要防止误把调试符号或全部 FFmpeg 静态库打进去。

### 9.2 启动时间优化

**分阶段打点**：

```swift
import OSLog

@main
struct PrismApp: App {
    private let launchSignposter = OSSignposter(logger: Log.ui)

    init() {
        let state = launchSignposter.beginInterval("Launch")
        defer { launchSignposter.endInterval("Launch", state) }
        // 只做最小初始化：不要在这里建数据库、不要发网络请求
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    // 首帧之后再做的重活
                    await bootstrap()
                }
        }
    }
}
```

**关键原则**：
1. **`@main` 的 `init` 里不做 I/O**。数据库连接、网络请求、图片预热全部推迟到首帧之后。
2. **数据库用 `DatabaseQueue` 而非 `DatabasePool`**（单连接更轻），除非有并发写需求。首次打开时 `PRAGMA journal_mode = WAL` 已由 GRDB 处理。
3. **`NSApplicationDelegateAdaptor` 里不做重活**。`applicationDidFinishLaunching` 只注册通知。
4. **延迟加载非首屏模块**。设置页、下载管理页的 ViewModel 用 `@State` 在 `.task` 里创建。
5. **避免在 `body` 里做计算**。任何 `filter`/`sort`/`map` 都要在 ViewModel 里预先算好。

**SwiftUI 启动陷阱**：
- `WindowGroup` 里嵌套多层 `NavigationSplitView` 会拖慢首帧。用 `columnVisibility` 控制，不要嵌套两个 SplitView。
- `@Query`（SwiftData）在启动时同步查询会阻塞。我们不用 SwiftData，但 GRDB 的 `ValueObservation` 也要注意：**首帧前不要 `for await`**。

### 9.3 大库滚动

**这是 Emby 客户端最常见的性能悬崖**：一个媒体库有 5000 张海报，滚动时每张都要下载 + 解码 + 缩放。

#### 方案：`LazyVGrid` + 图片降采样 + 预取

```swift
struct LibraryGrid: View {
    let items: [MediaItem]
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(items) { item in
                    PosterCard(item: item)
                        .onAppear { prefetch(item) }   // 预取邻近项
                }
            }
            .padding(20)
        }
    }
}
```

**四个关键优化**：

1. **`LazyVGrid` 只创建可见的 cell**（约 20–40 个），不是 5000 个。这是基础，但还不够。

2. **图片降采样到显示尺寸**。一张 1000×1500 的海报，显示在 180pt 宽（Retina 下 360px），如果直接解码原图，内存占用是 `1000×1500×4 = 6 MB`，而不是 `360×540×4 = 0.78 MB`。**这是最大的内存杀手**。

```swift
// Nuke 的降采样（在后台线程做，不阻塞主线程）
let request = ImageRequest(
    url: url,
    processors: [
        .resize(size: CGSize(width: 360, height: 540), contentMode: .aspectFill),
    ],
    priority: .normal
)
```

3. **固定 `id`，避免 SwiftUI 重建**。`ForEach(items, id: \.id)` 而不是 `ForEach(items, id: \.self)`（后者要求 `Hashable`，且内容变化时会重建）。

4. **预取策略**：`onAppear` 时预取「后面 20 个」，而不是「全部」。

```swift
private func prefetch(_ item: MediaItem) {
    guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
    let upcoming = items[index..<min(index + 20, items.count)]
    ImagePrefetcher.shared.startPrefetching(urls: upcoming.compactMap(\.posterURL))
}
```

5. **关闭隐式动画**。`LazyVGrid` 里的 `.animation()` 会让滚动掉帧。只在状态变化时显式加动画。

**测量方法**：

```bash
# 用 Instruments 的 Animation Hitches 模板，或用命令行
xctrace record --template 'Animation Hitches' \
  --launch build/Build/Products/Release/Prism.app \
  --time-limit 30s \
  --output hitches.trace
```

### 9.4 内存

**三个泄漏高发区**：

1. **`AsyncStream` 的 continuation 未终止**。如果订阅者被释放但流没结束，continuation 会持有闭包。
   - 对策：`onTermination` 里清理（§2.5 已实现），且 ViewModel 的 `deinit` 里 `task?.cancel()`。

2. **图片缓存无限增长**。Nuke 的 `DataCache` 有容量限制，但**内存缓存**要显式配置：
   ```swift
   var config = ImagePipeline.Configuration.withDataCache
   config.imageCache.costLimit = 128 * 1024 * 1024   // 128 MB
   config.imageCache.countLimit = 500
   ```

3. **`Task` 持有 `self`**。`Task { self.doWork() }` 会强引用 self，如果 Task 长期运行，self 就无法释放。
   - 对策：`Task { [weak self] in ... }`，但注意 `guard let self else { return }` 之后就是强引用了——在长循环里要每次检查。

**内存压力响应**：

```swift
NotificationCenter.default.addObserver(
    forName: NSApplication.didResignActiveNotification, ...
)
// 或更直接：
DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
```

> ⚠️ macOS 没有 iOS 的 `didReceiveMemoryWarning`。用 `DispatchSource.makeMemoryPressureSource`，在 `.warning` 时清空内存图片缓存。

### 9.5 MetricKit 与 OSLog 指标

**MetricKit 在 macOS 12+ 可用**（已核实：`introducedAt: '12.0'` for macOS）。

```swift
import MetricKit

final class MetricsCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsCollector()

    func register() {
        MXMetricManager.shared.add(self)
    }

    // 每 24 小时左右回调一次（系统决定）
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            // 启动时间
            if let launch = payload.applicationLaunchMetrics {
                let avg = launch.histogrammedTimeToFirstDraw
                Log.ui.info("launch histogram: \(String(describing: avg))")
            }
            // 挂起/内存
            if let memory = payload.memoryMetrics {
                Log.ui.info("peak memory: \(memory.peakMemoryUsage)")
            }
            // 卡顿
            if let hang = payload.applicationResponsivenessMetrics {
                Log.ui.info("hang time: \(hang.histogrammedApplicationHangTime)")
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            // 崩溃、卡死、CPU 异常
            for crash in payload.crashDiagnostics ?? [] {
                Log.ui.error("crash: \(crash.terminationReason ?? "unknown")")
            }
        }
    }
}
```

> ⚠️ **MetricKit 的数据只在本机**（写入 `MXMetricManager` 的存储，开发者可以用 `MXMetricManager` 的 `pastPayloads` 读）。**它不上传**。如果要做远程收集，需要自己把 payload 序列化后发送——但那就涉及隐私声明，v1.0 不做。**v1.0 的用途是**：本地开发时验证性能预算，以及用户主动导出诊断时附带。

**OSLog 的自定义指标**：

```swift
// 图片缓存命中率（用 signpost 的 event 计数）
signposter.emitEvent("ImageCacheHit")
signposter.emitEvent("ImageCacheMiss")

// 数据库查询耗时
let state = signposter.beginInterval("DBQuery", id: signposter.makeSignpostID())
defer { signposter.endInterval("DBQuery", state) }
```

**查看方式**：
```bash
# 实时流
log stream --predicate 'subsystem == "app.prism.Prism"' --level debug

# 导出最近 1 小时
log show --predicate 'subsystem == "app.prism.Prism"' --last 1h --info --debug > prism.log
```

### 9.6 启动/滚动性能的 CI 门禁（可选，但推荐）

```yaml
# .github/workflows/perf.yml（独立 workflow，只在 main 上跑）
name: Performance
on:
  push:
    branches: [main]

jobs:
  measure:
    runs-on: xcode-27
    steps:
      - uses: actions/checkout@v4
      - run: xcodegen generate
      - name: Build Release
        run: |
          xcodebuild -project Prism.xcodeproj -scheme Prism \
            -configuration Release -derivedDataPath build \
            -destination 'platform=macOS,arch=arm64' build
      - name: Measure launch
        run: |
          APP="build/Build/Products/Release/Prism.app"
          # 用 3 次取中位数，避免 CI 抖动
          for i in 1 2 3; do
            /usr/bin/time -p "$APP/Contents/MacOS/Prism" --measure-launch 2>&1 | tail -1
          done
```

> ⚠️ **CI 上的性能测量噪声很大**（共享 runner、虚拟化）。**建议只做趋势监控，不做硬门禁**，硬门禁放在本地 `scripts/perf.sh`。

---

## 10. 与现有文档的衔接

| 文档 | 关系 |
|---|---|
| `docs/ARCHITECTURE.md` | **冻结契约**。本文档的 §2（并发边界）、§4（数据层）是它的实现细化，**不修改它的签名**。 |
| `docs/ROADMAP.md` | §2 的技术决策与本文档一致；§4 的目录树与 §1.5 一致；§5 的 M5 发布里程碑对应本文档 §7。 |
| `docs/BUILD_ENV.md` | §4.1/§4.2 的 git 凭据与缓存规则是**强制**的，本文档 §6.1 直接引用。 |
| `docs/VERIFICATION.md` | 本文档 §6.6 的测试金字塔与它的验证流程对齐。 |
| `docs/research/ux-benchmark.md` | 界面清单（S01–S17）决定了 §9.3 的滚动性能优化要覆盖哪些屏幕。 |
| `docs/research/verified-facts.md` | **已核实事实库**（Emby 认证 / 发现 / 播放协商）。本文档 §5.3 的「用 `X-Emby-Token` header 而非 query」与它的 A3 一致；API 层细节一律以该文件为准，本文档不重复。 |
| `docs/research/emby-api.md` | Emby API 研究稿。本文档 §4.4 的 `UserData` 合并策略依赖它的字段定义；若两者冲突，**以 `verified-facts.md` 为准**。 |

---

## 11. 三个必须现在定下来的决策

### D1 · 部署目标：macOS 15.0 还是 27.0？

**现状**：`project.yml` / `Package.swift` / `ROADMAP` 都是 **15.0**；任务书描述的是模板原始状态 **27.0**。

| 选项 | 优点 | 缺点 |
|---|---|---|
| **15.0（推荐）** | 覆盖 macOS 15/26/27 三代系统；`@Entry`、`@Observable`、`NavigationSplitView` 都可用；与现有三份文档一致 | 用不了 macOS 26/27 的新 API（如新的窗口/材质 API） |
| 27.0 | 可用全部新 API | **只覆盖最新一代系统**，用户基数极小；CI runner 必须 `xcode-27`；Sparkle/Nuke 等依赖的 `minimumSystemVersion` 要跟着改 appcast |

**建议：保持 15.0。** 理由：一个 Emby 客户端的价值在于「能装在任何人的 Mac 上」，而不是「用上最新 API」。如果确实需要某个 macOS 26+ 的 API，用 `if #available(macOS 26, *)` 做渐进增强，而不是提高整体门槛。

**为什么必须现在定**：`Package.swift` 的 `platforms` 是**全局的**，改一次要重编译全部 target；`project.yml` 是受保护文件；Sparkle 的 `sparkle:minimumSystemVersion` 一旦发出去就改不了（老用户收不到更新）。

---

### D2 · 播放层是否拆成独立 SPM 包？

**现状**：`PrismPlayback` 在根 `Package.swift` 里，直接依赖 `MPVKit`。这意味着**任何人跑 `swift test` 都要先下载 150–200 MB**。

| 选项 | 优点 | 缺点 |
|---|---|---|
| **A. 保持单包（现状）** | 目录结构简单，与 `ROADMAP` §4 一致；依赖图一眼看全 | 首次构建慢；改 UI 也要等 MPVKit 下载；播放层编译错误阻塞所有人 |
| **B. 拆出 `Packages/PrismPlaybackKit`** | UI/Core 开发不碰 MPVKit；播放层可独立编译/测试；CI 可按 job 分层缓存 | 目录结构变化（需改 `ROADMAP`）；两处 `Package.swift` 要维护 |

**建议：B，但分两步走。** M0–M2 先保持单包（此时还没接 MPVKit，成本为零）；M3 接播放引擎时再拆。这样不会在项目初期引入结构复杂度。

**为什么必须现在定**：`ROADMAP` §4 的目录树是「所有权边界」，代理按它分配目录。**如果 M3 才拆，前面写的 `import PrismPlayback` 全要改路径**。

---

### D3 · 分发只走 Developer ID，还是保留 App Store 可能性？

**现状**：`ROADMAP` §2 已定「直接下载 + Developer ID」，本文档 §7.7 复核后同意。

| 选项 | 优点 | 缺点 |
|---|---|---|
| **A. 只走直接分发（推荐）** | 可用 Sparkle 自更新；可用 MPVKit（LGPL）；无审核 | 用户要手动下载、过 Gatekeeper；没有 App Store 的分发量 |
| **B. 双轨（直接 + App Store）** | 覆盖面最大 | 需要换播放引擎（AetherEngine 或 AVPlayer 方案）；移除 Sparkle；两套构建产物；审核成本 |

**建议：A，并且把「为什么不上 App Store」写进 README 与官网 FAQ**，避免用户反复问。

**为什么必须现在定**：这个决策决定了 ① 播放引擎选型（MPVKit vs AetherEngine）；② 是否引入 Sparkle；③ 签名/entitlements 策略。**这三件事在 M0 就要开始做**（Sparkle 的 `SUPublicEDKey` 要先生成，entitlements 要先定），拖到 M5 会导致返工。

---

## 12. 来源与置信度

### 12.1 已核实（附 URL）

| # | 事实 | 来源 | 核实方式 |
|---|---|---|---|
| 1 | `com.apple.security.app-sandbox` / `network.client` / `files.user-selected.read-write` / `files.downloads.read-write` 四个 key 的**准确拼写与语义** | [App Sandbox Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.app-sandbox)、[network.client](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client)、[files.user-selected.read-write](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write)、[files.downloads.read-write](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.downloads.read-write) | 逐条抓取 Apple 文档正文 |
| 2 | `NSAllowsLocalNetworking` 允许「unqualified domains、.local domains、IP addresses」；**macOS 14 起 ATS 默认不再允许直连 IP** | [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking) | 抓取文档原文（引文见 §5.4） |
| 3 | `notarytool` 的 `submit` / `--wait` / `--keychain-profile` / `--apple-id` / `--team-id` / `--password` / `--key` / `--key-id` / `--issuer` 全部存在；`altool` 自 2023-11-01 起不再被接受 | [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) | 文档 + 本机 `xcrun notarytool submit --help` 实测 |
| 4 | `stapler staple` / `stapler validate` 的用法；**zip 不能 staple** | 同上 + 本机 `xcrun stapler --help` | 文档 + 实测 |
| 5 | **Apple 明确不推荐用 `--deep` 签名**；`--deep` 只用于验证 | [TN2206: macOS Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) | 文档原文："While the `--deep` option can be applied to a signing operation, this is not recommended." |
| 6 | 公证要求：Hardened Runtime + **安全时间戳** + Developer ID 证书 + 无 `get-task-allow` | [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) | 文档原文 |
| 7 | Sparkle 2 沙盒需要 `SUEnableInstallerLauncherService=YES` + `temporary-exception.mach-lookup.global-name` 的 `-spks`/`-spki` | [Sandboxing with Sparkle](https://sparkle-project.org/documentation/sandboxing/) | 文档原文（引文见 §5.6） |
| 8 | Sparkle 2 的 `SUFeedURL` / `SUPublicEDKey` / `SUEnableAutomaticChecks` / `SUAutomaticallyUpdate` 语义；`generate_keys` 的用法与输出 | [Sparkle: Customizing](https://sparkle-project.org/documentation/customization/)、[Publishing](https://sparkle-project.org/documentation/publishing/)、[Getting Started](https://sparkle-project.org/documentation/) | 文档原文 |
| 9 | Sparkle 的 SPM 形态是 `binaryTarget`，工具在 `artifacts/sparkle/Sparkle/bin/` | [Sparkle Getting Started](https://sparkle-project.org/documentation/) + [Package.swift](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/Package.swift) | 文档 + 源码 |
| 10 | `sparkle:minimumSystemVersion` 必须是**三段式**；`sparkle:version` 不应是 git hash | [Publishing](https://sparkle-project.org/documentation/publishing/) | 文档原文 |
| 11 | GRDB **7.11.1**，`swift-tools-version:6.1`，要求 Xcode 16.3+/Swift 6.1+ | [GRDB Package.swift](https://raw.githubusercontent.com/groue/GRDB.swift/master/Package.swift)、[Releases](https://github.com/groue/GRDB.swift/releases) | 源码 + GitHub API |
| 12 | Nuke **13.2.0**，`swift-tools-version:6.0`，`macOS(.v13)`，产品 `Nuke`/`NukeUI`/`NukeVideo`/`NukeExtensions` | [Nuke Package.swift](https://raw.githubusercontent.com/kean/Nuke/main/Package.swift) | 源码 |
| 13 | Kingfisher **8.14.0**，`swift-tools-version:6.2`，`macOS(.v12)`，**`swiftLanguageModes: [.v5]`** | [Kingfisher Package.swift](https://raw.githubusercontent.com/onevcat/Kingfisher/master/Package.swift) | 源码 |
| 14 | MPVKit **1.1.0-n9.0.2**，`swift-tools-version:5.9`，`macOS(.v12)`，产品 `MPVKit`(LGPL) / `MPVKit-GPL`(GPL) | [MPVKit Package.swift](https://raw.githubusercontent.com/mpvkit/MPVKit/main/Package.swift)、[README](https://github.com/mpvkit/MPVKit) | 源码 + README |
| 15 | MPVKit release **36 个 asset、总计 449.2 MB**；`FFmpeg-all.zip` 91.4 MB、`Libavcodec.xcframework.zip` 58.3 MB、`Libmpv.xcframework.zip` 19.2 MB | 主管实测（2026-10-21），见任务派单 | 实测数据 |
| 16 | GitHub Actions **`xcode-27`** runner = macOS 27.0.1 (26A434)，预装 Xcode **27.1**（`/Applications/Xcode_27.1.app`）与 27.0（默认） | [runner-images README](https://github.com/actions/runner-images/blob/main/README.md)、[xcode-27-arm64 Readme](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) | 仓库原文 |
| 17 | `swiftLanguageModes` 是 `Package` 的属性；per-target 用 `swiftSettings: [.swiftLanguageMode(.v5)]`；tools-version 6.0 起默认 Swift 6 模式 | [Swift Migration Guide: EnableDataRaceSafety](https://github.com/swiftlang/swift-migration-guide/blob/main/Guide.docc/EnableDataRaceSafety.md)、[SE-0435](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0435-swiftpm-per-target-swift-language-version-setting.md) | 官方迁移指南 + 提案 |
| 18 | `SWIFT_STRICT_CONCURRENCY` 的取值 `minimal`/`targeted`/`complete`，且**仅在 Swift 4/4.2/5 模式生效**；`SWIFT_DEFAULT_ACTOR_ISOLATION` 取值 `nonisolated`/`MainActor`；`SWIFT_APPROACHABLE_CONCURRENCY` **仅在 Swift 5 模式生效** | `/Applications/Xcode.app/.../Swift.xcspec`（本机 Xcode 27.1） | 直接读 xcspec |
| 19 | `ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER` 的取值为 `""`/`readonly`/`readwrite`；`ENABLE_USER_SELECTED_FILES` 同 | `IDESwiftPackageCore` 二进制 + xcspec | 二进制字符串扫描 |
| 20 | macOS 15+ 有「本地网络隐私」，需要 `NSLocalNetworkUsageDescription`，否则**静默拒绝** | [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) | 文档原文 |
| 21 | MetricKit 在 **macOS 12+** 可用 | [MetricKit](https://developer.apple.com/documentation/metrickit)（`introducedAt: 12.0`） | 文档元数据 |
| 22 | VLC 因 GPL 与 App Store 冲突于 2011-01 被下架；2011-10 改为 LGPL，2013-07 以 MPL 重新上架 | [Ars Technica](http://arstechnica.com/apple/2011/01/vlc-for-ios-vanishes-2-months-after-eruption-of-gpl-dispute)、[Wikipedia: VLC media player](https://en.wikipedia.org/wiki/VLC_media_player) | 两家独立来源 |
| 31 | App Review Guidelines **2.5.2** 原文：App 须自包含，不得读写容器外数据，**不得下载/安装/执行会引入或改变功能的代码** | [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) | 抓取页面正文（引文见 §7.7） |
| 32 | `@Entry` 宏要求 iOS 18 / **macOS 15** / visionOS 2 / watchOS 11 / tvOS 18 起 | [SwiftUI Entry](https://developer.apple.com/documentation/swiftui/entry()) | 官方文档 availability |
| 33 | SE-0371 `isolated deinit` 状态为 **Implemented (Swift 6.2)** | [SE-0371](https://raw.githubusercontent.com/swiftlang/swift-evolution/main/proposals/0371-isolated-synchronous-deinit.md) | 提案原文 |
| 23 | AetherEngine 是 **LGPL-3.0 + App Store/DRM 例外**，v7.44.0 | [LICENSE](https://raw.githubusercontent.com/superuser404notfound/AetherEngine/main/LICENSE)、[Releases](https://github.com/superuser404notfound/AetherEngine/releases) | 源码 + API |
| 24 | XcodeGen **2.46.0** 的 `projectFormat` 可选值**不含 `xcode27_0`**（该值在 main 的 unreleased CHANGELOG 里） | [2.46.0 ProjectSpec.md](https://raw.githubusercontent.com/yonaskolb/XcodeGen/2.46.0/Docs/ProjectSpec.md)、[CHANGELOG](https://raw.githubusercontent.com/yonaskolb/XcodeGen/master/CHANGELOG.md) | 源码（tag 与 main 对比） |
| 25 | `.defaultIsolation(MainActor.self)` 需要 `_PackageDescription 6.2`；`.macOS(.v27)` 需要 6.4 | 本机 `PackageDescription.swiftinterface` | 直接读接口文件 |
| 26 | `defaultLocalization` 在有本地化资源时必需 | `PackageDescription.swiftinterface` + SPM 行为 | 接口文件 |
| 27 | KeychainAccess 最后 release 为 **v4.2.2（2021-03）**，最后 push 2024-05 | [GitHub API](https://api.github.com/repos/kishikawakatsumi/KeychainAccess) | API |
| 28 | Tuist 的 GitHub 许可证识别为 `NOASSERTION` | [GitHub API](https://api.github.com/repos/tuist/tuist) | API |
| 29 | `swift-tools-version: 6.4` 与 `.macOS(.v27)` 在**语法层面**被本机 Swift 6.4 接受（manifest 编译推进到 `-package-description-version 6.4.0` 阶段，才因沙盒/module cache 环境问题失败）；`.v27` 常量存在于 PackageDescription | 本机 `swift --version` + `PackageDescription.swiftinterface` + 一次 manifest 编译探测 | 实测 + 接口文件。**注意**：只验证了「版本号合法」，**未验证**完整构建成功 → 见 V3 |
| 30 | 模板工程原始 `objectVersion = 90`、`MACOSX_DEPLOYMENT_TARGET = 27.0`、`SWIFT_VERSION = 5.0`、`ENABLE_APP_SANDBOX = YES`、`ENABLE_USER_SELECTED_FILES = readonly` | 本机 `Prism.xcodeproj/project.pbxproj` + `xcodebuild -showBuildSettings` | 直接读 + 实测 |

### 12.2 待验证（需要在真实环境确认）

| # | 事项 | 为什么待验证 | 验证方式 |
|---|---|---|---|
| V1 | **MPVKit 的 dylib 在 `-exportArchive` 后是否已被 Xcode 正确签名** | Xcode 对 SwiftPM `binaryTarget` 的 embed & sign 行为随版本变化，我没有实际跑过完整 archive | 打一次 Release archive，`codesign --verify --deep --strict` + 公证看 log |
| V2 | **MPVKit 是否需要 `com.apple.security.cs.allow-jit` 或 `allow-unsigned-executable-memory`** | libplacebo/MoltenVK 的 Metal shader 编译路径可能触发 JIT 限制；无官方说明 | 在 hardened runtime 下实际播放 4K HDR，若崩溃再逐个加 entitlement 验证 |
| V3 | **`swift-tools-version: 6.4` 是否真的能在 Xcode 27.1 下完整构建带 MPVKit 的包** | 我只验证了 manifest 解析（`swift build` 因沙盒限制未能完成完整构建） | 在 `.spike/` 里用 `BUILD_ENV.md` §4.1 的命令跑一次 |
| V4 | **SwiftPM 是否按 target 图裁剪 binaryTarget 下载**（即「拆包能省 MPVKit 下载」是否成立） | SwiftPM 的依赖解析是包级的，`resolve` 会拉取所有依赖的 manifest；但 **artifact 下载**是否也全量，取决于实现 | 在干净目录跑 `swift build --target PrismCoreTests`，观察是否下载 MPVKit |
| V5 | **`xcode-27` runner 的稳定性**（当前是 preview） | 官方标为 preview（issue #14404） | 观察 2 周 CI 失败率，必要时回退 `macos-26` |
| V6 | **Sparkle 2.10 在沙盒 + `-exportArchive` 下的 XPC 签名是否正确** | Sparkle 官方说 Xcode 的 archive/export 会正确处理，但我没实测 | 发一次 beta，验证自动更新全流程 |
| V7 | **快照测试在 CI（无 GUI session）下能否渲染 `NSHostingView`** | macOS runner 有 WindowServer 吗？`NSHostingView` 离屏渲染通常可以，但字体渲染可能有差异 | 在 CI 上跑一次，对比本地基线 |
| V8 | **Emby 服务器是否接受 `X-Emby-Token` header 之外的鉴权方式**（如 query `api_key`） | 官方文档说 token 可放 header 或 query；我们只用 header，但某些旧版本服务器可能只认 query | 用 fixture + 真实服务器（用户提供后）验证 |
| V9 | **`NSAllowsLocalNetworking` 在 macOS 27 上对 `http://192.168.x.x` 是否仍然有效** | Apple 文档写到 macOS 14 的行为，后续版本未明确说明是否收紧 | 在 macOS 27 真机上连一台局域网 HTTP Emby 验证 |
| V10 | **`create-dmg` 产出的 DMG 是否影响公证** | DMG 里如果有自定义背景/图标布局，可能引入额外文件 | 公证一次看 log |

### 12.3 无法确认（明确标注，不当作事实）

| # | 事项 | 说明 |
|---|---|---|
| U1 | **LGPL-3.0 与 App Store 条款的法律结论** | 没有判例。FSF 认为冲突，Apple 未表态，VLC 的历史是「下架」而非「判决」。本文档的「不走 App Store」是**风险规避**，不是法律结论。 |
| U2 | **MPVKit 的长期维护性** | README 自称 "only suitable for learning libmpv and will not be maintained too frequently"，并推荐 AetherEngine 用于生产。**这是真实风险**，但没有替代品能满足「纯 libmpv + SPM」的需求。缓解：锁死版本 + 自建 fork 的预案。 |
| U3 | **XcodeGen 2.47 何时发布 `xcode27_0` 支持** | CHANGELOG 的 "Next Version" 有，但没有发布日期 |
| U4 | **Sparkle 2.10 是否完全兼容 macOS 27 的沙盒变更** | 官方未声明 macOS 27 的兼容性；需要实测（V6） |
| U5 | **`xcode-27` runner 上 `xcodebuild -exportArchive` 是否需要额外配置**（如 provisioning profile） | Developer ID 导出通常不需要 profile，但 CI 上的 keychain 配置需要实测 |
| U6 | **Emby 的 `PlaybackInfo` 返回的 `DirectStreamUrl` 是否总是可直接喂给 libmpv** | 取决于服务器的转码配置与容器格式；需要真实服务器验证 |
| U7 | **`String Catalog` 的 `STRING_CATALOG_GENERATE_SYMBOLS` 生成的符号，在 SPM target 里是否可用** | 该 setting 在 App target 上确定可用；SPM 资源 bundle 的符号生成行为未验证 |

---

## 13. 附：一页速查

```bash
# ── 日常 ──────────────────────────────────────────
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
swift build --disable-sandbox --cache-path "$PWD/.build/cache"
swift test  --disable-sandbox --cache-path "$PWD/.build/cache"

# ── 首次拉依赖（必须禁凭据助手，见 BUILD_ENV.md §4.1）──
env GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
    swift package resolve --disable-sandbox --cache-path "$PWD/.build/cache"

# ── 发布 ──────────────────────────────────────────
xcodebuild -project Prism.xcodeproj -scheme Prism -configuration Release \
  -derivedDataPath build -destination 'generic/platform=macOS' \
  -archivePath build/Prism.xcarchive \
  ARCHS="arm64 x86_64" ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" archive

xcodebuild -exportArchive -archivePath build/Prism.xcarchive \
  -exportPath build/export -exportOptionsPlist scripts/ExportOptions.plist

./scripts/sign.sh build/export/Prism.app          # 由内向外签名 + 验证
xcrun stapler staple build/export/Prism.app       # staple .app
./scripts/make-dmg.sh build/export/Prism.app 1.0.0 build
xcrun notarytool submit build/Prism-1.0.0.dmg \
  --keychain-profile prism-notary --wait
xcrun stapler staple build/Prism-1.0.0.dmg
xcrun stapler validate build/Prism-1.0.0.dmg
spctl -a -t exec -vv build/export/Prism.app       # 最后一道验证

# ── 更新源 ────────────────────────────────────────
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://prism.example.com/releases/" \
  --link "https://prism.example.com" \
  --embed-release-notes \
  build/releases/
```

```swift
// ── 并发速查 ──────────────────────────────────────
// ✅ Task { }            继承隔离/优先级/取消
// ✅ actor               串行化可变状态
// ✅ AsyncStream         跨域事件，带背压
// ✅ Sendable struct     跨域传值
// ❌ Task.detached       丢失隔离/取消
// ❌ DispatchQueue.main  与 Concurrency 混用
// ❌ @unchecked Sendable 关掉检查
```

```xml
<!-- ── Info.plist 速查 ───────────────────────────── -->
<key>NSAppTransportSecurity</key>
<dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSLocalNetworkUsageDescription</key>
<string>（本地化到 InfoPlist.xcstrings）</string>
<key>SUFeedURL</key><string>https://…/appcast.xml</string>
<key>SUPublicEDKey</key><string>（generate_keys 生成）</string>
<key>SUEnableInstallerLauncherService</key><true/>
```

---

<!-- END -->
