# Prism — macOS Emby 客户端 · 项目大纲与任务板

> 版本 v0.1 ｜ 主管：技术负责人 ｜ 更新：2026-10-21
> 状态：M0 地基进行中（脚手架 + 4 项技术调研并行）

---

## 1. 项目定位

**Prism** 是一个原生 macOS 的 Emby 客户端：SwiftUI 界面、libmpv 播放内核、本地缓存与离线能力，目标是「打开就能看、播得动、记得住进度」的桌面级观影应用。

**v1.0 成功标准（一句话）**：用户输入服务器地址登录后，能在 30 秒内找到一部电影/剧集并开始播放，退出后下次打开可一键续播。

**非目标（v1.0 明确不做）**：音乐库、Live TV/DVR、远程控制其他设备、多用户切换、App Store 上架、Windows/iOS 端。

---

## 2. 已确认的技术决策

| 决策项 | 结论 | 理由 |
|---|---|---|
| 语言/框架 | Swift 6 + SwiftUI，AppKit 仅用于播放器视图嵌入与窗口细节 | 原生体验、Swift 6 严格并发保证多代理协作质量 |
| 最低系统 | macOS 15 Sequoia（`MACOSX_DEPLOYMENT_TARGET = 15.0`） | 覆盖面与现代 API 的平衡点 |
| 播放内核 | **纯 libmpv（MPVKit / SPM）** | 格式覆盖最全：MKV/HEVC/DTS/TrueHD/ASS/PGS 一次到位，行为与 Emby 转码解耦 |
| 分发 | 直接下载 + Developer ID 签名 + notarytool 公证 + DMG + Sparkle 2 | 避开 App Store 沙盒与 GPL 组件的合规摩擦 |
| 工程组织 | 薄 App target + 根 SPM 包多 target，XcodeGen 生成工程 | 多代理并行时**零 pbxproj 冲突** |
| 数据层 | URLSession + async/await；GRDB 做元数据/进度缓存；Nuke 做图片缓存 | 成熟、可测、低维护 |
| 状态管理 | `@Observable` + `@MainActor` ViewModel；跨模块事件用 AsyncStream | 贴合 SwiftUI，避免第三方架构依赖 |

### 纯 libmpv 路线的已知代价（已接受）
- 系统画中画（PiP）与 AirPlay 不可直接用 → v1.0 先做「置顶迷你播放窗 + 系统级屏幕镜像」；v1.1 再评估 `AVSampleBufferDisplayLayer` 自研 PiP。
- Now Playing / 媒体键 / 睡眠防休眠需自实现 → 用 `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` + `IOPMAssertion`，与引擎解耦，成本可控。
- 公证时需对嵌入的 dylib 逐个签名并设置 hardened runtime 例外 → 在 M5 发布任务里单列。

### MPVKit 依赖核实结论（2026-10-21 主管验证）
- 仓库 `mpvkit/MPVKit`，最新 release `1.1.0-n9.0.2`（2026-10-07），`swift-tools-version:5.9`，`platforms: [.macOS(.v12)]` ✅
- 提供两个产品：`MPVKit`（**LGPL-3.0**，动态链接即可闭源分发）与 `MPVKit-GPL`（GPL，含 libsmbclient）。
- **本项目使用 LGPL 版 `MPVKit`**：Emby 走 HTTP/HTTPS，不需要 SMB；LGPL 下我们只需动态链接 + 提供库源码链接，App 本体可闭源。
- 依赖已内置 libass / libplacebo / MoltenVK / libdav1d / gnutls，ASS 字幕与 HDR tone-mapping 开箱可用。

---

## 3. 架构总览

```
┌──────────────────────────────────────────────┐
│ App/PrismApp.swift   @main · 窗口 · 菜单命令  │
└───────────────┬──────────────────────────────┘
                │ import
┌───────────────▼──────────────────────────────┐
│ PrismUI       设计系统 · 屏幕 · ViewModel     │
│  AppShell / Library / Detail / Player / ...   │
└──────┬───────────────────┬───────────────────┘
       │                   │
┌──────▼──────┐   ┌────────▼─────────┐   ┌──────────────┐
│ EmbyAPI     │   │ PrismPlayback    │   │ PrismData    │
│ Client/DTO  │   │ MPVKit 封装      │   │ GRDB/Keychain│
│ 端点/鉴权   │   │ 引擎/进度/字幕   │   │ 图片/离线    │
└──────┬──────┘   └────────┬─────────┘   └──────┬───────┘
       └───────────────┬───┴──────────────────────┘
                ┌──────▼──────┐
                │ PrismCore   │ 模型 · 日志 · 设置 · 工具
                └─────────────┘
```

**数据流（播放为例）**
`PlayerViewModel` → `PlaybackService`（协商 PlaybackInfo）→ `EmbyClient` → 选路（直连/转码）→ `MPVEngine.play(url)` → 事件流回推 UI → `ProgressReporter` 每 10s 上报 `/Sessions/Playing/Progress` → 退出时 `/Sessions/Playing/Stopped` 并写本地进度缓存。

**关键接口（先行冻结，代理按此实现）**
- `protocol EmbyEndpoint`：路径 + 查询参数 + 是否需要鉴权
- `actor EmbyClient`：`send<T: Decodable>(_ endpoint) async throws -> T`
- `protocol PlaybackEngine`：`play(url:headers:) / pause / seek(to:) / setRate / selectAudio / selectSubtitle / stateStream / renderView`
- `protocol MediaCache`：条目、图片、进度、离线索引

---

## 4. 仓库结构（目录即所有权边界）

```
Prism/
├── project.yml                 # XcodeGen 唯一事实来源（仅 scaffold/主管可改）
├── Package.swift               # 根 SPM 清单（仅 scaffold/主管可改）
├── App/                        # 薄壳：@main、菜单、窗口、entitlements
├── Sources/
│   ├── PrismCore/              # 模型、日志、设置、工具
│   ├── EmbyAPI/                # 网络层、DTO、端点
│   ├── PrismData/              # GRDB、Keychain、图片缓存、下载
│   ├── PrismPlayback/          # MPVKit 封装、引擎、字幕、进度上报
│   └── PrismUI/
│       ├── DesignSystem/       # 颜色/字体/间距/组件
│       ├── AppShell/           # 侧边栏、工具栏、导航
│       ├── Connect/            # 欢迎、发现、登录
│       ├── Library/            # 网格、筛选、分页
│       ├── Detail/             # 详情、季集
│       ├── Search/
│       ├── Player/             # 控制条、菜单、快捷键
│       └── Settings/
├── Tests/                      # 单元测试（每个 target 一个）
├── docs/                       # ROADMAP / ARCHITECTURE / research
├── scripts/                    # bootstrap/build/test/run/clean
└── .github/workflows/ci.yml
```

**规则**：一个代理只写自己 ticket 声明的目录；跨目录改动必须回到主管派单。`project.yml`、`Package.swift`、`ci.yml` 属于「受保护文件」，代理只能提需求，不能直接改。

---

## 5. 里程碑

| 里程碑 | 交付物 | 验收（Definition of Done） |
|---|---|---|
| **M0 地基** | 可构建可运行的骨架、脚本、CI、调研文档 | `./scripts/build.sh` 绿；`./scripts/run.sh` 弹出窗口；`swift test` 绿 |
| **M1 连得上** | 服务器发现/手动连接、登录、Keychain、多服务器 | 局域网自动发现出服务器；登录成功并重启后免登录；错误口令有明确提示 |
| **M2 看得见** | 首页、媒体库网格、详情页、搜索、图片缓存 | 1000 条目库滚动 60fps；海报不闪烁；断网有降级 UI |
| **M3 播得动** | libmpv 播放器、协商与转码、音轨字幕、全屏快捷键 | 直连播放 4K HEVC MKV 无卡顿；ASS 字幕正确渲染；切音轨即时生效 |
| **M4 用得顺** | 进度上报/续播、Now Playing、设置、空态错误态、本地化 | 退出重进进度误差 < 10s；媒体键可控；中英双语完整 |
| **M5 发得出** | 图标、DMG、签名公证、Sparkle、README | 在干净 Mac 上拖入 Applications 可启动；公证通过；更新检查可用 |

---

## 6. 任务板（按波次并行，依赖决定先后）

### Wave 0 — 调研与地基（进行中）

| ID | 任务 | 代理 | 依赖 | 验收 | 目录 |
|---|---|---|---|---|---|
| R1 | Emby API 全量参考（鉴权/条目/协商/进度/图片/WS/音乐/下载） | emby-api-researcher | — | 文档含端点表 + MVP 清单 + 坑位 | `docs/research/emby-api.md` |
| R2 | 播放引擎选型与 libmpv 落地/公证风险 | playback-architect | — | 对比矩阵 + 集成方案 + spike 计划 | `docs/research/playback.md` |
| R3 | 竞品对标 / IA / 界面清单 / 视觉 token | ux-researcher | — | 界面清单 + v1 范围切分 | `docs/research/ux-benchmark.md` |
| R4 | 工程化：SPM 布局、并发、沙盒、CI、公证、Sparkle | macos-engineer | — | 结构方案 + 3 个待定决策 | `docs/research/macos-engineering.md` |
| T0.1 | 仓库骨架、XcodeGen、脚本、CI、可运行 App | scaffold | — | build/test/run 全绿 + commit | 全仓库结构 |

### Wave 1 — 基础层（M0→M1）

| ID | 任务 | 代理 | 依赖 | 验收 | 目录 |
|---|---|---|---|---|---|
| T1.1 | `PrismCore`：Item/User/MediaSource 模型、Ticks 工具、日志、设置存储 | core-model | T0.1 | 模型单测覆盖 JSON 解码 | `Sources/PrismCore` |
| T1.2 | `EmbyAPI` 客户端：鉴权头、错误模型、重试、请求日志 | api-client | T1.1 | MockURLProtocol 单测绿 | `Sources/EmbyAPI/Client` |
| T1.3 | 端点集：Public/Auth/Views/Items/Images/Resume/NextUp/Search | api-endpoints | T1.2 | 每个端点有 fixture 测试 | `Sources/EmbyAPI/Endpoints` |
| T1.4 | 服务器发现：UDP 7359 广播 + 手动 URL 校验 | discovery | T1.2 | 模拟 UDP 响应可解析 | `Sources/EmbyAPI/Discovery` |
| T1.5 | 设计系统：色板/字阶/圆角/间距/动效 + 海报卡/骨架屏/空态组件 | design-system | T0.1 | 组件预览可用 | `Sources/PrismUI/DesignSystem` |
| T1.6 | 应用外壳：NavigationSplitView 侧边栏、工具栏、多服务器切换位 | app-shell | T1.5 | 空数据下导航可点 | `Sources/PrismUI/AppShell` |
| T1.7 | Keychain + 会话持久化 + 启动恢复 | session-store | T1.2 | 重启免登录；401 自动登出 | `Sources/PrismData/Session` |
| T1.8 | MPVKit 集成 spike：SPM 引入、渲染到 NSView、ASS 字幕、切音轨 | mpv-spike | T0.1 | Demo 能播 MKV 并切字幕 | `Sources/PrismPlayback/Spike` |

### Wave 2 — 连接与浏览（M1→M2）

| ID | 任务 | 代理 | 依赖 | 验收 | 目录 |
|---|---|---|---|---|---|
| T2.1 | 欢迎页 + 服务器列表 + 手动地址 + 登录表单 | connect-ui | T1.4,T1.5,T1.7 | 全流程可走通，错误态清晰 | `Sources/PrismUI/Connect` |
| T2.2 | 首页：继续观看 / 最新添加 / 接下来 | home-feed | T1.3,T2.3 | 真实数据渲染，横向滚动流畅 | `Sources/PrismUI/Home` |
| T2.3 | 图片管线：降采样、磁盘缓存、tag 失效、模糊占位 | image-pipeline | T1.1 | 1000 图内存 < 300MB | `Sources/PrismData/Images` |
| T2.4 | 库网格：LazyVGrid、hover、右键菜单、排序筛选、无限分页 | library-grid | T1.3,T2.3 | 万条库滚动不掉帧 | `Sources/PrismUI/Library` |
| T2.5 | 详情页（电影/剧集）：元数据、演职员、季集、相似、播放按钮 | detail-ui | T1.3,T2.3 | 两种布局完整；续播按钮正确 | `Sources/PrismUI/Detail` |
| T2.6 | 搜索：防抖、分组、键盘上下选择 | search-ui | T1.3 | 输入 300ms 内出结果 | `Sources/PrismUI/Search` |

### Wave 3 — 播放（M3）

| ID | 任务 | 代理 | 依赖 | 验收 | 目录 |
|---|---|---|---|---|---|
| T3.1 | `MPVEngine`：播放/暂停/seek/倍速/音量/事件流/渲染层 | mpv-engine | T1.8 | 长片 seek 精准 ±0.5s | `Sources/PrismPlayback/Engine` |
| T3.2 | 协商：DeviceProfile、PlaybackInfo、直连/转码选路、失败降级 | playback-negotiation | T1.3,T3.1 | 三种播放方式都能出画面 | `Sources/PrismPlayback/Negotiation` |
| T3.3 | 播放器 UI：控制条、进度悬停预览、音轨/字幕菜单、全屏、自动隐藏 | player-ui | T3.1,T1.5 | 键鼠全流程无死角 | `Sources/PrismUI/Player` |
| T3.4 | 进度上报与续播：Playing/Progress/Stopped、90% 完播判定 | progress-sync | T3.1,T1.3 | 退出重进误差 <10s | `Sources/PrismPlayback/Progress` |
| T3.5 | Now Playing + 媒体键 + 防休眠 + 迷你置顶窗 | now-playing | T3.1 | 控制中心显示元数据与进度 | `Sources/PrismPlayback/System` |
| T3.6 | 字幕：内嵌/外挂、ASS 样式、延迟、字体、位置 | subtitles | T3.1 | ASS 特效正常，延迟可调 | `Sources/PrismPlayback/Subtitles` |

### Wave 4 — 打磨（M4）

| ID | 任务 | 代理 | 依赖 | 验收 | 目录 |
|---|---|---|---|---|---|
| T4.1 | 设置页：播放/字幕/网络/外观/关于 + 持久化 | settings-ui | T1.5 | 改完即生效并持久化 | `Sources/PrismUI/Settings` |
| T4.2 | 全局错误与空态：超时、断网、服务器不可达、空库 | resilience | T2.4 | 每种错误有可恢复动作 | 各 UI 目录（统一组件） |
| T4.3 | 本地化：String Catalog，中英双语 | localization | 全 UI | 切换语言无截断 | `Sources/**/Localizable.xcstrings` |
| T4.4 | 性能：启动 <1.5s、滚动、内存、图片解码线程 | perf | M2 | Instruments 无泄漏 | 跨模块（只读审查） |
| T4.5 | 应用图标 + 关于页 + 首次启动引导 | branding | T4.1 | 图标各尺寸齐全 | `App/Assets.xcassets` |

### Wave 5 — 发布（M5）

| ID | 任务 | 代理 | 依赖 | 验收 | 目录 |
|---|---|---|---|---|---|
| T5.1 | 签名与公证：Developer ID、dylib 逐个签名、notarytool、staple | release | M4 | `spctl -a -vv` 通过 | `scripts/release.sh` |
| T5.2 | DMG 打包 + Sparkle appcast + 版本策略 | packaging | T5.1 | 干净 Mac 安装可启动 | `scripts/`、`docs/RELEASE.md` |
| T5.3 | QA 清单：冒烟用例、边界用例、回归矩阵 | qa | M4 | 清单全绿或已知问题登记 | `docs/QA.md` |
| T5.4 | README/用户指南/贡献指南 | docs-writer | M4 | 新人 10 分钟能跑起来 | `README.md`、`docs/` |

### v1.1+ 待办（不进 v1.0）
下载与离线播放、音乐库、Live TV、多用户、远程控制、自研 PiP、播放列表、Trakt 同步、Apple TV 端。

---

## 7. 智能体团队编制

| 角色 | 职责 | 关键约束 |
|---|---|---|
| **主管（我）** | 拆单、定接口、审阅、合并、拍板 | 不写业务代码，只写架构与门禁 |
| 调研代理 ×4 | 一次性产出知识文档 | 只写 `docs/research/` |
| 基础设施代理 | 工程结构、脚本、CI | 独占 `project.yml`/`Package.swift` |
| 模块代理（按 Wave 派单） | 单 ticket 实现 + 自测 | 只写自己目录；完成即交报告 |
| 审查代理 | 交叉 code review、找并发/内存/边界问题 | 只读 + 提 issue，不改代码 |
| QA 代理 | 构建、跑测、冒烟、回归 | 只读 + 写 `docs/QA.md` |

**协作协议（每个代理必须遵守）**

0. **【事实核查，最高优先级】任何不确定的技术事实，必须先联网搜索再落笔，禁止凭印象编造。**
   - 适用范围：API 路径/参数名、库的许可证、版本号、平台限制、配置项名称、性能数字、竞品功能、系统 API 可用性。
   - 每份技术结论都要能回答「证据在哪」。文档里给**可点击的来源 URL**；代码注释里给文档链接。
   - 无法证实的，必须显式标注 `【待验证】` 并说明验证方法，**不允许用肯定语气陈述未验证内容**。
   - 三方交叉：官方文档 > 官方仓库源码/Release > 社区讨论。冲突时以官方为准并注明分歧。
   - 复核规则：凡涉及「这个 API 存在吗 / 这个库能不能用 / 这个参数叫什么」的判断，至少查一次；查不到就写「查不到」，不许猜。
   - 违者打回重做，且该 ticket 不计入完成。

1. 开工前读 `docs/ROADMAP.md` 与自己 ticket 的验收标准；接口以本文第 3 节为准。

1.1 **【安全红线】禁止触碰用户凭据。** 拉取 GitHub 依赖必须禁用凭据助手，否则会弹出 macOS 钥匙串授权框打断用户（已发生事故）。
   标准前缀见 `docs/BUILD_ENV.md` §4.1；验证目录一律放工作区 `.spike/`，不用 `/tmp`。
   禁止：`security unlock-keychain`、`security find-generic-password`、改 `git config --global`、诱导用户点「允许」。
2. 只写 ticket 声明的目录；需要跨目录改动 → 报告主管，不自行越界。
3. 完成前自测：`swift build` + 相关 `swift test`；UI 任务附截图或预览说明。
4. 交报告格式：**改动文件清单 / 自测命令与结果 / 未完成项与风险 / 需要主管决策的问题**。
5. 提交信息 `feat(<scope>): <中文摘要>`；不 push、不改 CI 凭证、不引入未经批准的依赖。
6. 禁止：硬编码服务器地址或 token、`try!`、无 `@MainActor` 的 UI 状态突变、阻塞主线程的 IO。

**主管审阅门禁（每个 ticket 必过）**
- [ ] 编译零 error，新增 warning ≤ 3 且已说明
- [ ] 公共 API 有文档注释，命名符合 Swift API Design Guidelines
- [ ] 并发安全：`Sendable` 边界清晰，UI 状态在主 actor
- [ ] 有错误路径处理与用户可见文案（中英）
- [ ] 有测试或可复现的手动验证步骤
- [ ] 无越界文件改动

---

## 8. 风险登记册

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| 1 | libmpv 无系统 PiP/AirPlay | 体验缺口 | v1 用置顶迷你窗 + 屏幕镜像；v1.1 评估自研 PiP |
| 2 | MPVKit 与 Swift 6 严格并发冲突 | 编译阻塞 | spike 先行（T1.8），必要时对封装层用 `@preconcurrency` |
| 3 | 嵌入 dylib 公证失败 | 无法分发 | T5.1 单列，先做签名脚本再谈功能 |
| 4 | 无真实 Emby 服务器联调 | 集成盲区 | **需用户提供测试服务器**，或本地 Docker 起 Emby |
| 5 | Emby 版本差异（4.8/4.9/Jellyfin） | 兼容问题 | 协商逻辑做能力探测，不硬编码版本 |
| 6 | 多代理同改一文件 | 冲突 | 目录所有权 + 受保护文件清单 |
| 7 | 无 Apple Developer ID 证书 | 无法公证 | 开发期 ad-hoc 签名；发布前需用户提供证书 |

---

## 9. 执行节奏

- **每波次**：主管拆单 → 并行派发（3–6 个代理）→ 代理自测交报告 → 主管审阅/打回 → 合并 → 下一波。
- **每日**：一次全量 `build + test` 回归，红则冻结新派单先修。
- **里程碑**：M1/M2/M3 各做一次真机（真服务器）验收，验收不过不推进。

---

## 10. 现在需要你确认/提供

1. **测试服务器**：一台可访问的 Emby（地址 + 账号密码，或允许我用 Docker 本地起一个）。
2. **Apple Developer ID**：发布阶段需要（M5 之前给即可）。
3. 对第 2 节技术决策如有异议，现在提出；否则我按此推进。
