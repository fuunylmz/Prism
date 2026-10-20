# 决策备忘 002：开源 + 播放引擎重新选型

> 主管 ｜ 2026-10-21 ｜ 状态：**引擎选型待用户拍板，开源条款待定**
> 前置：[DECISION-mpv-license.md](DECISION-mpv-license.md)（该文的许可证困境在开源后已解除）

---

## 1. 开源决定的影响：许可证问题消失

LGPL-3.0 §4(d)(0) 的唯一实质义务是「提供 Corresponding Application Code，且其条款允许用户重新链接修改版库」。

**源码公开后，这条自动满足**——不论 Prism 用 MIT、Apache-2.0 还是 GPL-3.0。
所以：

| 原方案 | 开源后 |
|---|---|
| A：静态链接 + 发布附目标文件 | ❌ 不再需要 |
| B：自建动态 libmpv | ❌ 不再需要 |
| C：换 VLCKit | ❌ 不再需要 |

**结论：许可证不再是选型约束。** 可以纯按「哪个引擎更好用」来选。

---

## 2. 我先前给你的选项不完整

我给的两个选项是「AVPlayer + 转码」和「libmpv」，你选了 libmpv。但我当时**漏掉了一个选项**，而且它可能是最合适的。这是我的失误。

### 2.1 AetherEngine 是什么（已核实）

| 项 | 事实 | 来源 |
|---|---|---|
| 仓库 | `superuser404notfound/AetherEngine` | GitHub API |
| 许可证 | **LGPL-3.0 + App Store / DRM 例外** | LICENSE 文件原文 |
| 活跃度 | 最新 release `7.44.0`，**2026-10-20**（昨天）；仓库同日有推送 | GitHub API |
| 星标 | 265 | GitHub API |
| 平台 | iOS 18 / tvOS 18 / **macOS 15** / visionOS 1 | `Package.swift` |
| 工具链 | **Swift 6.4 / Xcode 27.0** | README Requirements |
| 形态 | **纯 Swift 源码包**（非 binaryTarget），依赖 FFmpegBuild 等 | `Package.swift` |
| 架构 | FFmpeg demux + VideoToolbox 解码 + AVPlayer 处理 Atmos/DV | README |

**已落地案例**（README "Used by"）：Sodalite（**Jellyfin 原生客户端**）、AetherPlayer（macOS 播放器）、Silo、Moonfin 等 16 个，含多个 App Store 上架应用。

### 2.2 关键差异：它解决了 libmpv 的全部硬伤

| 能力 | MPVKit (libmpv) | AetherEngine |
|---|---|---|
| 系统画中画 PiP | ❌ 需自研 | ✅ `AVPictureInPictureController` 原生 |
| AirPlay 视频 | ❌ 不支持 | ✅ 原生路径支持 |
| Dolby Vision / HDR10+ | ◐ 靠 libplacebo tone-mapping | ✅ 系统级 DV 直通 |
| Dolby Atmos | ❌ 解码为 PCM | ✅ EAC3+JOC 直通 |
| ASS 字幕 | ✅ libass 完整渲染 | ✅ 文本轨 + 可选 raw ASS markup + 字体 |
| PGS 字幕 | ✅ | ✅ 且可 OCR 转 WebVTT 以在 PiP 中显示 |
| Now Playing / 媒体键 | 需自实现 | ✅ 原生路径天然可用 |
| Swift 互操作 | ❌ C API + OpaquePointer | ✅ 纯 Swift，`@Published` 状态 |
| 维护状态 | ⚠️ README：「不适合生产，不会频繁维护」 | ✅ 昨天还在发版 |
| 集成体积 | 静态库约 350 MB 下载 | 待测（依赖 FFmpegBuild 动态框架） |

**它的 API 几乎就是我们的 `PlaybackEngine` 协议：**

```swift
let player = try AetherEngine()
var body: some View { AetherPlayerSurface(engine: player) }   // SwiftUI 直接可用

try await player.load(url: videoURL, startPosition: 347.5,
                      options: .init(httpHeaders: embyHeaders))  // ← Emby 鉴权头
player.play(); player.pause(); player.setRate(1.5); await player.seek(to: 120)
player.$state   // .idle/.loading/.playing/.paused/.seeking/.ended/.error
player.$errorInfo  // 结构化错误
player.subtitleTracks / selectSubtitleTrack(index:) / $subtitleCues
```

对比 libmpv 需要 `mpv_set_option_string(mpv, "wid", ...)`、`mpv_observe_property`、C 回调、`OpaquePointer` 隔离——**工作量差一个数量级**。

### 2.3 它的风险（必须说清）

| 风险 | 说明 | 缓解 |
|---|---|---|
| 单人维护 | 作者 Vincent Herbst，265 星 | 锁版本 + 可 fork（LGPL 允许） |
| 年轻 | 7.x 线刚抬升平台门槛（原 iOS 16/macOS 14） | 锁定 7.44.0，不跟 latest |
| 依赖链 | 依赖 FFmpegBuild / LibDovi / LibTrueHD 等多个同作者包 | 全部锁定 exact 版本 |
| 体积未知 | 未实测最终 .app 增量 | M3 首个集成任务实测 |
| XcodeGen 不支持 traits | README 明确：2.45.4 会静默丢弃 `traits:` | 我们不用 traits（默认全关），不受影响 |

---

## 3. 主管建议

**改用 AetherEngine，放弃 MPVKit。**

理由按权重排序：
1. **它解决了 PiP 和 AirPlay** —— 这两个是我们确认的、libmpv 无法弥补的功能缺口，对 macOS 桌面观影体验影响极大。
2. **它是纯 Swift** —— 我们不用写 `OpaquePointer` 隔离层，不用担心 Swift 6 严格并发与 C 指针的冲突，`PlaybackEngine` 协议能几乎 1:1 映射。
3. **它更活跃** —— MPVKit 自己说「不适合生产」；AetherEngine 昨天还在发版，且有 Jellyfin 客户端在用。
4. **它原生处理 DV/Atmos** —— libmpv 在这两项上是弱项，而 Emby 库里的 4K 片源恰恰常见。

**保留 MPVKit 作为 Plan B**：如果 M3 集成时 AetherEngine 出现阻塞性问题（编译不过、性能不达标），`PlaybackEngine` 协议让我们能在两周内切回 MPVKit。

---

## 4. 开源条款建议

源码公开后许可证不再是约束，所以按**产品目标**选：

| 许可证 | 适合 | 代价 |
|---|---|---|
| **MIT**（推荐） | 想让别人用、想收贡献、想积累口碑 | 别人可以拿去做闭源商业版 |
| Apache-2.0 | 同上，且要专利授权条款 | 文本较长，贡献者要签 CLA 更顺 |
| GPL-3.0 | 要求衍生作品必须开源 | 部分公司禁止使用，贡献者变少 |

**我推荐 MIT**：Emby/Jellyfin 生态的第三方客户端多数是宽松许可证，MIT 最容易融入社区。

需要同时做的事：
- 仓库根放 `LICENSE`（MIT 全文）
- `THIRD-PARTY-NOTICES.md` 列出 AetherEngine（LGPL-3.0 + 例外）、FFmpeg（LGPL）、LibDovi 等
- README 写明「本项目使用 AetherEngine（LGPL-3.0），其源码见 <tag 链接>」
- **不要**把 FFmpeg 动态框架合并进主二进制（LGPL 要求保持可替换）

---

## 5. 主管实测结果（2026-10-21，已跑通）

在 `.spike/engine/` 建了独立 spike 包（`.package(url: AetherEngine, exact: "7.44.0")`），
用加固后的 git 环境（见 `docs/BUILD_ENV.md` §4.1）解析并构建。

### 5.1 构建结果 ✅

```
Build complete! (30.71秒)
```

运行：

```
AetherEngine 构造成功
状态: idle
支持的最大倍速: 2.0
是否支持缓存静帧: false
```

**全程零钥匙串弹窗。** 证明加固后的 git 环境对 SwiftPM 依赖解析同样有效。

### 5.2 关键发现：FFmpeg 是**动态框架**，LGPL 合规天然满足 ✅

`otool -L` 显示 spike 二进制链接的是：

```
@rpath/AetherLibavcodec.framework/Versions/A/AetherLibavcodec
@rpath/AetherLibavformat.framework/Versions/A/AetherLibavformat
@rpath/AetherLibavutil.framework/Versions/A/AetherLibavutil
@rpath/AetherLibswresample.framework/Versions/A/AetherLibswresample
@rpath/AetherLibswscale.framework/Versions/A/AetherLibswscale
@rpath/AetherLibavfilter.framework/Versions/A/AetherLibavfilter
@rpath/AetherLibdav1d.framework/Versions/A/AetherLibdav1d
@rpath/AetherLibzimg.framework/Versions/A/AetherLibzimg
@rpath/AetherLibzvbi.framework/Versions/A/AetherLibzvbi
```

**这是动态框架，不是静态库** —— 与 MPVKit（`current ar archive`，静态）形成鲜明对比。
AetherEngine 的 README 也明确要求「FFmpeg 框架必须保持动态嵌入在 `YourApp.app/Frameworks/`，
不能合并进主二进制」，这正是 LGPL 的精神。

**结论：LGPL 合规是「按设计即可满足」，不需要任何额外工作**（我们本来就要逐个签名嵌入的 dylib）。

### 5.3 体积实测（macOS arm64 slice）

| 框架 | 类型 | arm64 大小 |
|---|---|---|
| AetherLibavcodec | 动态 | 6.1 MB |
| AetherLibavformat | 动态 | 1.1 MB |
| AetherLibswscale | 动态 | 1.1 MB |
| AetherLibdav1d | 动态 | 0.8 MB |
| AetherLibavutil | 动态 | 0.7 MB |
| AetherLibzvbi | 动态 | 0.5 MB |
| AetherLibavfilter | 动态 | 0.4 MB |
| AetherLibzimg | 动态 | 0.3 MB |
| AetherLibswresample | 动态 | 0.1 MB |
| **合计** | | **≈ 11.1 MB** |

- spike 可执行文件（含 AetherEngine 的 Swift 代码 + 我们的代码）：**25.3 MB**
- **预计 .app 增量：约 35–45 MB**（11 MB 框架 + Swift 静态代码 + 资源），
  远小于 MPVKit 路线。**DMG 预估 40–60 MB**。

### 5.4 依赖解析成本（CI 规划用）

```
.build/repositories   422 MB      # git clone 总体积
.build（含编译产物）  1.6 GB
```

**注意**：FFmpegBuild 把 9 个 `.xcframework` **直接放在源码树里**
（`Sources/Aether*.xcframework` + `binaryTarget(path:)`），所以走的是**普通 git clone**，
不涉及 Xcode 的二进制产物下载机制。

四个仓库体积：`FFmpegBuild` 171 MB、`LibDovi` 160 MB、`SMBClient` 45 MB、`AetherEngine` 19 MB。

- `SMBClient` 是 `AetherEngineSMB` target 的依赖，我们**不用**该 product，
  `otool -L` 确认它**没有被链接**；但 SwiftPM 仍会 clone 它（45 MB 纯浪费）。
- CI 必须缓存 `.build/repositories`，否则每次构建都要重新 clone 422 MB。

### 5.5 已确认的待验证项

| 项 | 状态 |
|---|---|
| `maxSupportedRate` = 2.0 | ✅ 实测确认（视频 2x） |
| `supportsCacheBackedStills` = false | ✅ 实测（未启用 `DolbyVisionStillReshaping` trait） |
| 音量 API | ⬜ 待查（协议里有 `setVolume`，AetherEngine 文档未见） |
| 实际播放 MKV / ASS 字幕 | ⬜ 待 T1.8 用真实文件验证 |
| 公证与 `@rpath` 重写 | ⬜ 待 M5 验证 |

### 5.6 决策：现在**不**把 AetherEngine 加进主 `Package.swift`

原因：SPM 会解析根包的全部依赖（不论哪个 target 用），一旦加入，
每个 `swift build` 都要 clone 422 MB，拖慢当前并行开发的六个代理。
**计划在 M3（播放波次）开始时才加**，同时把 `PrismPlayback` 拆成独立包
（与工程化调研的 D2 建议一致）。

---

## 6. 待用户确认

1. **引擎是否改用 AetherEngine？**（我建议改；不改则维持 MPVKit + 自研 PiP）
2. **开源许可证选哪个？**（我建议 MIT）
3. 仓库是否直接建在 GitHub 上？要不要我生成 README/LICENSE/CONTRIBUTING 三件套？
